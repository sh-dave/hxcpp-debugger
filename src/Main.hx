import protocol.debug.Types;
import js.node.Buffer;
import js.node.Net;
import js.node.ChildProcess;
import js.node.child_process.ChildProcess.ChildProcessEvent;
import js.node.net.Socket.SocketEvent;
import js.node.stream.Readable.ReadableEvent;
import hxcpp.debug.jsonrpc.Protocol;

typedef HxppLaunchRequestArguments = {
    >protocol.debug.Types.LaunchRequestArguments,
    var program:String;
    var workingDirectory:String;
}

@:keep
class Main extends adapter.DebugSession {

    function traceToOutput(value:Dynamic, ?infos:haxe.PosInfos) {
        var msg = value;
        if (infos != null && infos.customParams != null) {
            msg += " " + infos.customParams.join(" ");
        }
        msg += "\n";
        sendEvent(new adapter.DebugSession.OutputEvent(msg));
    }

    override function initializeRequest(response:InitializeResponse, args:InitializeRequestArguments) {
        haxe.Log.trace = traceToOutput;
        sendEvent(new adapter.DebugSession.InitializedEvent());
        response.body.supportsSetVariable = true;
        response.body.supportsValueFormattingOptions = false;
        response.body.supportsConfigurationDoneRequest = true;
        sendResponse(response);
        postLaunchActions = [];
    }

    var connection:Connection;
    var postLaunchActions:Array<(Void->Void)->Void>;

    function executePostLaunchActions(callback) {
        function loop() {
            var action = postLaunchActions.shift();
            if (action == null)
                return callback();
            action(loop);
        }
        loop();
    }

    override function launchRequest(response:LaunchResponse, args:LaunchRequestArguments) {
        var args:HxppLaunchRequestArguments = cast args;
        var executable = args.program;
        var workingDirectory = args.workingDirectory;

        function onConnected(socket) {
            trace("Debug server connected!");
            connection = new Connection(socket);
            socket.on(SocketEvent.Error, function (error) trace('Socket error: $error'));

            executePostLaunchActions(function() {
                continueRequest(cast response, {threadId:0});
                connection.onEvent = onEvent;
            });
        }

        function onExit(_, _) {
            sendEvent(new adapter.DebugSession.TerminatedEvent(false));
        }

        var server = Net.createServer(onConnected);
        server.listen(6972, function() {
            var port = server.address().port;
            var args = [];
            var haxeProcess = ChildProcess.spawn(executable, args, {stdio: Pipe, cwd: workingDirectory});
            haxeProcess.stdout.on(ReadableEvent.Data, onStdout);
            haxeProcess.stderr.on(ReadableEvent.Data, onStderr);
            haxeProcess.on(ChildProcessEvent.Exit, onExit);
        });
    }

    override function configurationDoneRequest(response:ConfigurationDoneResponse, args:ConfigurationDoneArguments) {
        sendResponse(response);
    }

    function onStdout(data:Buffer) {
        sendEvent(new adapter.DebugSession.OutputEvent(data.toString("utf-8"), stdout));
    }

    function onStderr(data:Buffer) {
        sendEvent(new adapter.DebugSession.OutputEvent(data.toString("utf-8"), stderr));
    }

    //var stopContext:StopContext;

    function onEvent<P>(type:NotificationMethod<P>, data:P) {
        switch (type) {
            case Protocol.PauseStop:
                sendEvent(new adapter.DebugSession.StoppedEvent("pause", data.threadId));

            case Protocol.BreakpointStop:
                //stopContext = new StopContext(connection);
                sendEvent(new adapter.DebugSession.StoppedEvent("breakpoint", data.threadId));

            case Protocol.ExceptionStop:
                //stopContext = new StopContext(connection);
                var evt = new adapter.DebugSession.StoppedEvent("exception", 0);
                evt.body.text = data.text;
                sendEvent(evt);

            case Protocol.ThreadStart:
                var evt = new adapter.DebugSession.ThreadEvent(ThreadEventReason.started, data.threadId);
                sendEvent(evt);

            case Protocol.ThreadExit:
                var evt = new adapter.DebugSession.ThreadEvent(ThreadEventReason.exited, data.threadId);
                sendEvent(evt);
        }
    }

    override function scopesRequest(response:ScopesResponse, args:ScopesArguments) {
        connection.sendCommand(Protocol.GetScopes, args, function(error, scopeInfos) {
            var scopes:Array<Scope> = [];
            response.body = {
                scopes:scopes
            }
            for (si in scopeInfos) {
                scopes.push({
                    name:si.name,
                    variablesReference:si.id,
                    expensive:false
                });
            };
            sendResponse(response);
        });
    }

    override function variablesRequest(response:VariablesResponse, args:VariablesArguments) {
        connection.sendCommand(Protocol.GetVariables, args, function(error, varInfos) {
            var vars:Array<Variable> = [];
            response.body = {variables:vars};
            for (vi in varInfos) {
                var variable:Variable = {
                    name:vi.name,
                    value:Std.string(vi.value),
                    type:vi.type,
                    //kind:vi.type,
                    variablesReference:vi.variablesReference
                };
                if (vi.indexedVariables != null) variable.indexedVariables = vi.indexedVariables;
                if (vi.namedVariables != null) variable.namedVariables = vi.namedVariables;
                //trace(haxe.Json.stringify(variable));
                vars.push(variable);

            }
            sendResponse(response);
        });
    }

    override function setVariableRequest(response:SetVariableResponse, args:SetVariableArguments) {
        /*
        stopContext.setVariable(args.variablesReference, args.name, args.value, function(varInfo) {
            if (varInfo != null)
                response.body = {value: varInfo.value};
            sendResponse(response);
        });
        */
    }

    override function stepInRequest(response:StepInResponse, args:StepInArguments) {
        connection.sendCommand(Protocol.StepIn, {}, function(_,_) {
            sendResponse(response);
            sendEvent(new adapter.DebugSession.StoppedEvent("step", 0));
        });
    }

    override function stepOutRequest(response:StepOutResponse, args:StepOutArguments) {
        connection.sendCommand(Protocol.StepOut, {}, function(_,_) {
            sendResponse(response);
            sendEvent(new adapter.DebugSession.StoppedEvent("step", 0));
        });
    }

    override function nextRequest(response:NextResponse, args:NextArguments) {
        connection.sendCommand(Protocol.Next, {}, function(_,_) {
            sendResponse(response);
            sendEvent(new adapter.DebugSession.StoppedEvent("step", 0));
        });
    }

    override function stackTraceRequest(response:StackTraceResponse, args:StackTraceArguments) {
        connection.sendCommand(Protocol.StackTrace, {threadId:args.threadId}, function(error, result) {
            var r:Array<StackFrame> = [];
            for (info in result) {
                r.push({
                    id: info.id,
                    name: info.name,
                    source: {path: info.source},
                    line: info.line,
                    column: info.column,
                    endLine: info.endLine,
                    endColumn: info.endColumn,
                });
            }
            response.body = {
                stackFrames: r
            };
            sendResponse(response);
        });
    }

    override function threadsRequest(response:ThreadsResponse) {
        connection.sendCommand(Protocol.Threads, null, function(error, result) {
            response.body = {threads:result};
            sendResponse(response);
        });
    }

    override function pauseRequest(response:PauseResponse, args:PauseArguments) {
        connection.sendCommand(Protocol.Pause, {});
        sendResponse(response);
    }

    override function continueRequest(response:ContinueResponse, args:ContinueArguments) {
        connection.sendCommand(Protocol.Continue, args, function(_,_) sendResponse(response));
    }

    override function setBreakPointsRequest(response:SetBreakpointsResponse, args:SetBreakpointsArguments) {
        if (connection == null)
            postLaunchActions.push(function(cb) doSetBreakpoints(response, args, cb));
        else
            doSetBreakpoints(response, args, null);
    }

    function doSetBreakpoints(response:SetBreakpointsResponse, args:SetBreakpointsArguments, callback:Null<Void->Void>) {
        var params:SetBreakpointsParams = {
            file: args.source.path,
            breakpoints: [for (sbp in args.breakpoints) {
                var bp:{line:Int, ?column:Int, ?condition:String} = {line: sbp.line};
                if (sbp.column != null) bp.column = sbp.column;
                if (sbp.condition != null) bp.condition = sbp.condition;
                bp;
            }]
        }
        connection.sendCommand(Protocol.SetBreakpoints, params, function(error, result) {
            response.body = {breakpoints: [for (bp in result) {verified: true, id: bp.id}]};
            sendResponse(response);
            if (callback != null)
                callback();
        });
    }

    override function evaluateRequest(response:EvaluateResponse, args:EvaluateArguments) {
        connection.sendCommand(Protocol.Evaluate, {expr:args.expression, frameId:args.frameId}, function(error, result) {
            if (error != null) {
                response.message = error.message;
                response.success = false;
            } else {
                response.success = true;
                response.body = {
                    result:result.value,
                    type:result.type,
                    variablesReference:result.variablesReference
                };
                if (result.indexedVariables != null) response.body.indexedVariables = result.indexedVariables;
                if (result.namedVariables != null) response.body.namedVariables = result.namedVariables;
            }
            sendResponse(response);
        });
    }

    override function setExceptionBreakPointsRequest(response:SetExceptionBreakpointsResponse, args:SetExceptionBreakpointsArguments) {
        // TODO: this should finish before the debugger runs, else the settings are missed
        //connection.sendCommand(Protocol.SetExceptionOptions, args.filters, function(error, result) {
        //	sendResponse(response);
        //});
    }

    static function main() {
        adapter.DebugSession.run(Main);
    }
}