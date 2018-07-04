package hxcpp.debug.jsonrpc;

import hxcpp.debug.jsonrpc.VariablesPrinter;
import hxcpp.debug.jsonrpc.Protocol;
#if cpp
import cpp.vm.Thread;
import cpp.vm.Mutex;
import cpp.vm.Debugger;
import cpp.vm.Deque;
#else
typedef Mutex = Dynamic;
#end

@:enum abstract ScopeId(String) to String {
    var members = "Members";
    var locals = "Locals";
}

private class References {
    static var lastId:Int = 1000;
    var references:Map<Int, Value>;

    public function new() { 
        references = new Map<Int, Value>();
    }

    public function create(ref:Value):Int {
        var id = lastId;
        references[lastId] = ref;
        lastId++;
        return id;
    }

    public function get(id:Int):Value {
        return references[id];
    }

    public function clear() {
        references = new Map<Int, Value>();
    }
}

@:keep
class Server {

    var host:String;
    var port:Int;
    var socket:sys.net.Socket;
    var stateMutex:Mutex;
    var socketMutex:Mutex;
    var currentThreadInfo:cpp.vm.ThreadInfo;
    var scopes:Map<ScopeId, Array<String>>;
    var threads:Map<Int, String>;
    var breakpoints:Map<String, Array<Int>>;
    var references:References;
    var started:Bool;

    static var startQueue:Deque<Bool> = new Deque<Bool>();
    
    @:keep static var inst = {
        var host:String = Macro.getDefinedValue("HXCPP_DEBUG_HOST", "127.0.0.1");
        var port:Int = Std.parseInt(Macro.getDefinedValue("HXCPP_DEBUG_PORT", "6972"));
        new Server(host, port);
    }
    
    public function new(host:String, port:Int) {
        trace('Debug Server Started:');
        this.host = host;
        this.port = port;
        stateMutex = new Mutex();
        socketMutex = new Mutex();
        scopes = new Map<ScopeId, Array<String>>();
        breakpoints = new Map<String, Array<Int>>();
        references = new References();
        threads = new Map<Int, String>();
        
        connect();

        Debugger.enableCurrentThreadDebugging(false);
        Thread.create(debuggerThreadMain);
        startQueue.pop(true);
        Debugger.enableCurrentThreadDebugging(true);
    }

    private function connect() {
        var socket : sys.net.Socket = new sys.net.Socket();

        while (true) {
            try {
                var host = new sys.net.Host(host);
                if (host.ip == 0) {
                    throw "Name lookup error.";
                }
                socket.connect(host, port);
                log('Connected to vsc debugger server at $host:$port');

                this.socket = socket;
                return;
            }
            catch (e : Dynamic) {
                log('Failed to connect to vsc debugger server at $host:$port');
            }
            closeSocket();
            log("Trying again in 3 seconds.");
            Sys.sleep(3);
        }
    }

    private function debuggerThreadMain() {
       Debugger.setEventNotificationHandler(handleThreadEvent);
       Debugger.enableCurrentThreadDebugging(false);
       Debugger.breakNow(true);

       var fullPathes = Debugger.getFilesFullPath();
       var files = Debugger.getFiles();
       var path2file = new Map<String, String>();
       var file2path = new Map<String, String>();
       for (i in 0...files.length) {
           var file = files[i];
           var path = fullPathes[i];
           path2file[path.toUpperCase()] = file;
           file2path[file.toUpperCase()] = path;
       }
       startQueue.push(true);

        try {
            while (true) {
                var m = readMessage();
                switch (m.method) {
                    case Protocol.SetBreakpoints:
                        var params:SetBreakpointsParams = m.params;
                        var result = [];
                        
                        if (!breakpoints.exists(params.file)) breakpoints[params.file] = [];
                    
                        for (rm in breakpoints[params.file]) {
                            Debugger.deleteBreakpoint(rm);
                        }
                        for (b in params.breakpoints) {
                            var id = Debugger.addFileLineBreakpoint(path2file[params.file.toUpperCase()], b.line);
                            result.push(id);
                        }
                        breakpoints[params.file] = result;
                        m.result = result;

                    case Protocol.Pause:
                        Debugger.breakNow(true);

                    case Protocol.Continue:
                        Debugger.continueThreads(m.params.threadId, 1);

                    case Protocol.Threads:
                        stateMutex.acquire();
                        m.result = [for (tid in threads.keys()) {id:tid, name:threads[tid]}];
                        stateMutex.release();

                    case Protocol.GetScopes:
                        m.result = [];

                        stateMutex.acquire();
                        if (currentThreadInfo != null) {
                            var threadId:Int = currentThreadInfo.number;
                            var frameId:Int = m.params.frameId;

                            var stackVariables:Array<String> = Debugger.getStackVariables(threadId, frameId, false);
                            var localsId = 0;
                            var localsNames:Array<String> = [];
                            var localsVals:Array<Dynamic> = [];
                            for (varName in stackVariables) {
                                if (varName == "this") {
                                    var inner = new Map<String, Dynamic>();
                                    var value:Dynamic = Debugger.getStackVariableValue(threadId, frameId, "this", false);
                                    var id = references.create(VariablesPrinter.resolveValue(value));
                                    m.result.push({id:id, name:ScopeId.members});
                                } else {
                                    if (localsId == 0) {
                                        localsId = references.create(NameValueList(localsNames, localsVals));
                                        m.result.push({id:localsId, name:ScopeId.locals});
                                    }
                                    localsNames.push(varName);
                                    localsVals.push(Debugger.getStackVariableValue(threadId, frameId, varName, false));
                                }
                            }
                        }
                        stateMutex.release();

                    case Protocol.GetVariables:
                        m.result = [];

                        stateMutex.acquire();

                        if (currentThreadInfo != null) {
                            var refId = m.params.variablesReference;
                            var value:Value = references.get(refId);
                            var vars = VariablesPrinter.getInnerVariables(value, m.params.start, m.params.count);

                            //trace(vars);
                            for (v in vars) {
                                var varInfo:VarInfo = {
                                    name:v.name,
                                    type:v.type,
                                    value:"",
                                    variablesReference:0,
                                }
                                switch (v.value) {
                                    case NameValueList(names, values):
                                        throw "impossible";

                                    case IntIndexed(value, length, _):
                                        var refId = references.create(v.value);
                                        varInfo.variablesReference = refId;
                                        varInfo.indexedVariables = length;

                                    case StringIndexed(value, names, _):
                                        var refId = references.create(v.value);
                                        varInfo.variablesReference = refId;
                                        varInfo.namedVariables = names.length;

                                    case Single(value):
                                        varInfo.value = value;
                                }
                                m.result.push(varInfo);
                            }
                        }
                        stateMutex.release();

                    case Protocol.Evaluate:
                        var expr = m.params.expr;

                        stateMutex.acquire();
                        if (currentThreadInfo != null) {
                            var threadId = currentThreadInfo.number;
                            var frameId = m.params.frameId;
                            var v = VariablesPrinter.evaluate(expr, threadId, frameId);
                            m.result = {
                                name:expr,
                                value:"",
                                type:"",
                                variablesReference:0
                            };
                            if (v != null) {
                                m.result.type = v.type;
                                switch (v.value) {
                                    case NameValueList(names, values):
                                        throw "impossible";

                                    case IntIndexed(value, length, _):
                                        var refId = references.create(v.value);
                                        m.result.variablesReference = refId;
                                        m.result.indexedVariables = length;

                                    case StringIndexed(value, names, _):
                                        var refId = references.create(v.value);
                                        m.result.variablesReference = refId;
                                        m.result.namedVariables = names.length;

                                    case Single(value):
                                        m.result.value = value;
                                }
                            }
                        }
                        stateMutex.release();

                    case Protocol.StackTrace:
                        m.result = [];

                        stateMutex.acquire();
                        if (currentThreadInfo != null) {
                            var frameNumber = currentThreadInfo.stack.length - 1;
                            var i = 0;
                            for (s in currentThreadInfo.stack) {
                                if (s.fileName == "hxcpp/debug/jsonrpc/Server.hx") break;
                                
                                m.result.unshift({
                                    id:i++,
                                    name:'${s.className}.${s.functionName}',
                                    source:file2path[s.fileName.toUpperCase()],
                                    line:s.lineNumber,
                                    column:0,
                                    artificial:false
                                });
                            }
                        }
                        stateMutex.release();

                    case Protocol.Next:
                        Debugger.stepThread(0, Debugger.STEP_OVER, 1);

                    case Protocol.StepIn:
                        Debugger.stepThread(0, Debugger.STEP_INTO, 1);

                    case Protocol.StepOut:
                        Debugger.stepThread(0, Debugger.STEP_OUT, 1);

                }
                sendResponse(m);
            }
        }
    }

    private function readMessage():Message {
        var length:Int = socket.input.readInt16();
        trace('Message Length: $length');
        var rawString = socket.input.readString(length);
        return haxe.Json.parse(rawString);
    }

    private function sendResponse(m:Message) {
        socketMutex.acquire();
        var serialized:String = haxe.Json.stringify(m);
        socket.output.writeInt16(serialized.length);
        socket.output.writeString(serialized);
        trace('sendResponse: ${m.id} ${m.method}');
        socketMutex.release();
    }

    private function sendEvent<T>(event:NotificationMethod<T>, ?params:T) {
        var m = {
            method:event,
            params:params
        };
        sendResponse(m);
    }

    function handleThreadEvent(threadNumber : Int, event : Int,
                                       stackFrame : Int,
                                       className : String,
                                       functionName : String,
                                       fileName : String, lineNumber : Int)
    {
        trace(event);
        //if (!started) return;

        switch (event) {
            case Debugger.THREAD_TERMINATED:
                stateMutex.acquire();
                threads.remove(threadNumber);
                if (currentThreadInfo != null && threadNumber == currentThreadInfo.number) {
                    currentThreadInfo = null;
                }
                stateMutex.release();
                sendEvent(Protocol.ThreadExit, {threadId:threadNumber});

            case Debugger.THREAD_CREATED | Debugger.THREAD_STARTED:
                stateMutex.acquire();
                threads.set(threadNumber, 'Thread${threadNumber}');
                if (currentThreadInfo != null && threadNumber == currentThreadInfo.number) {
                    currentThreadInfo = null;
                }
                stateMutex.release();
                sendEvent(Protocol.ThreadStart, {threadId:threadNumber});
            case Debugger.THREAD_STOPPED:
                
                stateMutex.acquire();
                currentThreadInfo = Debugger.getThreadInfo(threadNumber, false);
                references.clear();
                stateMutex.release();

                if (currentThreadInfo.status == cpp.vm.ThreadInfo.STATUS_STOPPED_BREAK_IMMEDIATE) {
                    sendEvent(Protocol.PauseStop, {threadId:threadNumber});
                }
                else if (currentThreadInfo.status == cpp.vm.ThreadInfo.STATUS_STOPPED_BREAKPOINT) {
                    sendEvent(Protocol.BreakpointStop, {threadId:threadNumber});
                }
                else {
                    sendEvent(Protocol.ExceptionStop, {text:currentThreadInfo.criticalErrorDescription});
                }
                //ThreadStopped(threadNumber, stackFrame, className,
                //                functionName, fileName, lineNumber));
         
        }
    }

    private function closeSocket() {
        if (socket != null) {
            socket.close();
            socket = null;
        }
    }

    public static function log(message:String) {
        trace(message);
    }
}