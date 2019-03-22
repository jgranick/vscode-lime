package lime.extension;

import js.node.Buffer;
import js.node.ChildProcess;
import sys.FileSystem;
import haxe.io.Path;
import haxe.DynamicAccess;
import Vscode.*;
import vscode.*;

using lime.extension.ArrayHelper;
using Lambda;

class Main
{
	private static var instance:Main;

	private var context:ExtensionContext;
	private var displayArgumentsProvider:DisplayArgsProvider;
	private var disposables:Array<{function dispose():Void;}>;
	private var hasProjectFile:Bool;
	private var initialized:Bool;
	private var isProviderActive:Bool;
	private var selectTargetItem:StatusBarItem;
	private var targetItems:Array<TargetItem>;
	private var targetLabels:Array<String>;
	private var targets:Array<String>;
	private var haxeEnvironment:DynamicAccess<String>;
	private var limeCommands:Array<LimeCommand>;
	private var limeExecutable:String;
	private var limeVersion:SemVer = "0.0.0";

	public function new(context:ExtensionContext)
	{
		this.context = context;

		registerDebugConfigurationProviders();

		context.subscriptions.push(workspace.onDidChangeConfiguration(workspace_onDidChangeConfiguration));
		refresh();
	}

	private function checkHasProjectFile():Void
	{
		hasProjectFile = false;

		if (getProjectFile() != "")
		{
			hasProjectFile = true;
		}

		if (!hasProjectFile)
		{
			// TODO: multi-folder support

			var wsFolder = if (workspace.workspaceFolders == null) null else workspace.workspaceFolders[0];
			var rootPath = wsFolder.uri.fsPath;

			if (rootPath != null)
			{
				// TODO: support custom project file references

				var files = ["project.xml", "Project.xml", "project.hxp", "project.lime"];

				for (file in files)
				{
					if (FileSystem.exists(rootPath + "/" + file))
					{
						hasProjectFile = true;
						break;
					}
				}
			}
		}
	}

	private function construct():Void
	{
		disposables = [];

		selectTargetItem = window.createStatusBarItem(Left, 9);
		selectTargetItem.tooltip = "Select Target Configuration";
		selectTargetItem.command = "lime.selectTarget";
		disposables.push(selectTargetItem);

		disposables.push(commands.registerCommand("lime.selectTarget", selectTargetItem_onCommand));
		disposables.push(tasks.registerTaskProvider("lime", this));
	}

	private function deconstruct():Void
	{
		if (disposables == null)
		{
			return;
		}

		for (disposable in disposables)
		{
			disposable.dispose();
		}

		selectTargetItem = null;

		disposables = null;
		initialized = false;
	}

	private function constructDisplayArgumentsProvider()
	{
		var api:Vshaxe = getVshaxe();

		displayArgumentsProvider = new DisplayArgsProvider(api, function(isProviderActive)
		{
			this.isProviderActive = isProviderActive;
			refresh();
		});

		if (untyped !api)
		{
			trace("Warning: Haxe language server not available (using an incompatible vshaxe version)");
		}
		else
		{
			api.registerDisplayArgumentsProvider("Lime", displayArgumentsProvider);
		}
	}

	private function createTask(command:String, additionalArgs:Array<String>, presentation:vshaxe.TaskPresentationOptions, problemMatchers:Array<String>,
			group:TaskGroup = null)
	{
		command = StringTools.trim(command);

		var definition:LimeTaskDefinition =
			{
				type: "lime",
				command: command
			}

		var shellCommand = limeExecutable + " " + command;
		if (additionalArgs != null) shellCommand += " " + additionalArgs.join(" ");

		var task = new Task(definition, TaskScope.Workspace, command, "lime");
		task.execution = new ShellExecution(shellCommand,
			{
				cwd: workspace.workspaceFolders[0].uri.fsPath,
				env: haxeEnvironment
			});

		if (group != null)
		{
			task.group = group;
		}

		task.problemMatchers = problemMatchers;
		task.presentationOptions =
			{
				reveal: presentation.reveal,
				echo: presentation.echo,
				focus: presentation.focus,
				panel: presentation.panel,
				showReuseMessage: presentation.showReuseMessage,
				clear: presentation.clear
			};

		return task;
	}

	private function getCommandArguments(command:String, targetItem:TargetItem):String
	{
		var target = targetItem.target;
		var args = (targetItem.args != null ? targetItem.args.copy() : []);

		var projectFile = getProjectFile();
		if (projectFile != "")
		{
			args.unshift(projectFile);
		}

		// TODO: Should this be separate?

		if (target == "windows" || target == "mac" || target == "linux")
		{
			// TODO: Update task when extension is installed?
			if (hasExtension("vshaxe.hxcpp-debugger"))
			{
				args.push("--haxelib=hxcpp-debug-server");
			}
		}
		else if (target == "flash" && args.indexOf("-debug") > -1)
		{
			args.push("-Dfdb");
		}

		return command + " " + target + " " + args.join(" ");
	}

	private function getExecutable():String
	{
		var executable = workspace.getConfiguration("lime").get("executable");
		if (executable == null)
		{
			executable = "lime";
		}
		// naive check to see if it's a path, or multiple arguments such as "haxelib run lime"
		if (FileSystem.exists(executable))
		{
			executable = '"' + executable + '"';
		}
		return executable;
	}

	private function getLimeVersion():Void
	{
		try
		{
			var output = ChildProcess.execSync(limeExecutable + " -version", {cwd: workspace.workspaceFolders[0].uri.fsPath});
			limeVersion = StringTools.trim(Std.string(output));
		}
		catch (e:Dynamic)
		{
			limeVersion = "0.0.0";
			trace(e);
		}
	}

	public function getProjectFile():String
	{
		var config = workspace.getConfiguration("lime");

		if (config.has("projectFile"))
		{
			var projectFile = Std.string(config.get("projectFile"));
			if (projectFile == "null") projectFile = "";
			return projectFile;
		}
		else
		{
			return "";
		}
	}

	public function getTargetItem():TargetItem
	{
		var defaultTargetConfig = workspace.getConfiguration("lime").get("defaultTargetConfiguration", "HTML5");
		var defaultTargetItem = targetItems.find(function(item)
		{
			return item.label == defaultTargetConfig;
		});

		if (defaultTargetItem != null)
		{
			defaultTargetConfig = defaultTargetItem.label;
		}

		var targetConfig = context.workspaceState.get("lime.targetConfiguration", defaultTargetConfig);
		var targetItem = targetItems.find(function(item)
		{
			return item.label == targetConfig;
		});

		if (targetItem == null)
		{
			targetItem = defaultTargetItem;
		}

		return targetItem;
	}

	private inline function getVshaxe():Vshaxe
	{
		return extensions.getExtension("nadako.vshaxe").exports;
	}

	private function hasExtension(id:String, shouldInstall:Bool = false, message:String = ""):Bool
	{
		if (extensions.getExtension(id) == js.Lib.undefined)
		{
			if (shouldInstall)
			{
				// TODO: workbench.extensions.installExtension not available?
				// var installNowLabel = "Install Now";
				// window.showErrorMessage(message, installNowLabel).then(function(selection)
				// {
				// 	trace(selection);
				// 	if (selection == installNowLabel)
				// 	{
				// 		commands.executeCommand("workbench.extensions.installExtension", id);
				// 	}
				// });
				window.showWarningMessage(message);
			}
			return false;
		}
		else
		{
			return true;
		}
	}

	private function initialize():Void
	{
		getLimeVersion();

		// TODO: Detect automatically?

		limeCommands = [CLEAN, UPDATE, BUILD, RUN, TEST];

		// TODO: Allow additional configurations

		targets = ["android", "flash", "html5", "neko"];
		targetLabels = ["Android", "Flash", "HTML5", "Neko"];

		if (limeVersion >= new SemVer(8, 0, 0))
		{
			targets.push("hl");
			targetLabels.push("HashLink");
		}

		switch (Sys.systemName())
		{
			case "Windows":
				targets = targets.concat(["windows", "air", "electron"]);
				targetLabels = targetLabels.concat(["Windows", "AIR", "Electron"]);

			case "Linux":
				targets.push("linux");
				targetLabels.push("Linux");

			case "Mac":
				targets = targets.concat(["mac", "ios", "tvos", "air", "electron"]);
				targetLabels = targetLabels.concat(["macOS", "iOS", "tvOS", "AIR", "Electron"]);

			default:
		}

		updateTargetItems();

		getVshaxe().haxeExecutable.onDidChangeConfiguration(function(_) updateHaxeEnvironment());
		updateHaxeEnvironment();

		initialized = true;
	}

	private function updateHaxeEnvironment()
	{
		var haxeConfiguration = getVshaxe().haxeExecutable.configuration;
		var env = new DynamicAccess();

		for (field in Reflect.fields(haxeConfiguration.env))
		{
			env[field] = haxeConfiguration.env[field];
		}

		if (!haxeConfiguration.isCommand)
		{
			var separator = Sys.systemName() == "Windows" ? ";" : ":";
			env["PATH"] = Path.directory(haxeConfiguration.executable) + separator + Sys.getEnv("PATH");
		}

		haxeEnvironment = env;
	}

	@:keep @:expose("activate") public static function activate(context:ExtensionContext)
	{
		instance = new Main(context);
	}

	@:keep @:expose("deactivate") public static function deactivate()
	{
		instance.deconstruct();
	}

	static function main() {}

	public function provideDebugConfigurations(folder:Null<WorkspaceFolder>, ?token:CancellationToken):ProviderResult<Array<DebugConfiguration>>
	{
		trace("provideDebugConfigurations");
		return [
			{
				"name": "Lime",
				"type": "lime",
				"request": "launch"
			}];
	}

	public function provideTasks(?token:CancellationToken):ProviderResult<Array<Task>>
	{
		var targetItem = getTargetItem();
		var vshaxe = getVshaxe();
		var displayPort = vshaxe.displayPort;
		var problemMatchers = vshaxe.problemMatchers.get();
		var presentation = vshaxe.taskPresentation;

		var commandGroups = [TaskGroup.Clean, null, TaskGroup.Build, null, TaskGroup.Test];
		var tasks = [];

		var args = [];
		if (vshaxe.enableCompilationServer && displayPort != null /*&& args.indexOf("--connect") == -1*/)
		{
			args.push("--connect");
			args.push(Std.string(displayPort));
		}

		for (item in targetItems)
		{
			for (command in limeCommands)
			{
				var task = createTask(getCommandArguments(command, item), args, presentation, problemMatchers);
				tasks.push(task);
			}
		}

		for (i in 0...limeCommands.length)
		{
			var command = limeCommands[i];
			var commandGroup = commandGroups[i];

			var task = createTask(getCommandArguments(command, targetItem), args, presentation, problemMatchers, commandGroup);
			task.name = command + " (current)";
			tasks.push(task);
		}

		var task = createTask("run html5 -nolaunch", args, presentation, ["$lime-nolaunch"]);
		task.isBackground = true;
		tasks.push(task);

		var task = createTask("test html5 -nolaunch", args, presentation, ["$lime-nolaunch"]);
		task.isBackground = true;
		tasks.push(task);

		return tasks;
	}

	private function refresh():Void
	{
		checkHasProjectFile();

		if (hasProjectFile)
		{
			if (displayArgumentsProvider == null)
			{
				constructDisplayArgumentsProvider();
			}

			var oldLimeExecutable = limeExecutable;
			limeExecutable = getExecutable();
			var limeExecutableChanged = oldLimeExecutable != limeExecutable;

			if (isProviderActive && (!initialized || limeExecutableChanged))
			{
				if (!initialized)
				{
					initialize();
					construct();
				}

				updateDisplayArguments();
			}
		}

		if (!hasProjectFile || !isProviderActive)
		{
			deconstruct();
		}

		if (initialized)
		{
			updateTargetItems();
			updateStatusBarItems();
		}
	}

	private function registerDebugConfigurationProviders():Void
	{
		debug.registerDebugConfigurationProvider("chrome", this);
		debug.registerDebugConfigurationProvider("fdb", this);
		debug.registerDebugConfigurationProvider("hl", this);
		debug.registerDebugConfigurationProvider("hxcpp", this);
		debug.registerDebugConfigurationProvider("lime", this);
	}

	public function resolveDebugConfiguration(folder:Null<WorkspaceFolder>, config:DebugConfiguration,
			?token:CancellationToken):ProviderResult<DebugConfiguration>
	{
		if (config != null && config.type == null)
		{
			return null; // show launch.json
		}

		if (!hasProjectFile || !isProviderActive) return config;

		if (limeVersion < new SemVer(8, 0, 0))
		{
			var message = 'Lime debug support requires Lime 8.0.0 (or greater)';
			window.showWarningMessage(message);
			return config;
		}

		if (config != null && config.type == "lime")
		{
			var config:Dynamic = config;
			var target = getTargetItem().target;
			var outputFile = null;

			var targetLabel = "Unknown Target";
			for (i in 0...targets.length)
			{
				if (targets[i] == target)
				{
					targetLabel = targetLabels[i];
					break;
				}
			}

			var supportedTargets = ["flash", "windows", "mac", "linux", "html5"];
			#if debug
			supportedTargets.push("hl");
			#end
			if (supportedTargets.indexOf(target) == -1)
			{
				window.showWarningMessage("Debugging " + targetLabel + " is not supported");
				return js.Lib.undefined;
			}

			switch (target)
			{
				case "hl":
					if (!hasExtension("HaxeFoundation.haxe-hl", true, "Debugging HashLink requires the \"HashLink Debugger\" extension"))
					{
						return js.Lib.undefined;
					}

				case "flash":
					if (!hasExtension("vshaxe.haxe-debug", true, "Debugging Flash requires the \"Flash Debugger\" extension"))
					{
						return js.Lib.undefined;
					}

				case "html5":
					if (!hasExtension("msjsdiag.debugger-for-chrome", true, "Debugging HTML5 requires the \"Debugger for Chrome\" extension"))
					{
						return js.Lib.undefined;
					}

				default:
					if (!hasExtension("vshaxe.hxcpp-debugger", true, "Debugging " + targetLabel + " requires the \"HXCPP Debugger\" extension"))
					{
						return js.Lib.undefined;
					}
			}

			var targetItem = getTargetItem();
			var commandLine = limeExecutable + " " + getCommandArguments("display", targetItem) + " --output-file";
			commandLine = StringTools.replace(commandLine, "-verbose", "");

			try
			{
				var output = ChildProcess.execSync(commandLine, {cwd: workspace.workspaceFolders[0].uri.fsPath});
				outputFile = StringTools.trim(Std.string(output));
			}
			catch (e:Dynamic)
			{
				trace(e);
			}

			config.preLaunchTask = "lime: build";

			switch (target)
			{
				case "flash":
					config.type = "fdb";
					config.program = "${workspaceFolder}/" + outputFile;

				case "hl":
					// TODO: Waiting for HL debugger to have a way to use a custom exec
					config.type = "hl";
					config.program = "${workspaceFolder}/" + Path.directory(outputFile) + "/hlboot.dat";
					config.exec = "${workspaceFolder}/" + outputFile;

				case "html5", "electron":
					// TODO: Get webRoot path from Lime
					// TODO: Get source maps working
					// TODO: Let Lime tell us what server and port
					// TODO: Support other debuggers? Firefox debugger?
					config.type = "chrome";
					config.url = "http://127.0.0.1:3000";
					// config.file = "${workspaceFolder}/" + Path.directory(outputFile) + "/index.html";
					config.sourceMaps = true;
					// config.smartStep = true;
					// config.internalConsoleOptions = "openOnSessionStart";
					config.webRoot = "${workspaceFolder}/" + Path.directory(outputFile);
					config.preLaunchTask = "lime: test html5 -nolaunch";

				case "windows", "mac", "linux":
					config.type = "hxcpp";
					config.program = "${workspaceFolder}/" + outputFile;

				default:
					return null;
			}
		}
		return config;
	}

	public function resolveTask(task:Task, ?token:CancellationToken):ProviderResult<Task>
	{
		// This method is never called
		// https://github.com/Microsoft/vscode/issues/33523
		// Hopefully this will work in the future for custom configured issues

		// TODO: Validate command name and target?
		// TODO: Get command list and target list from Lime?
		// var definition:LimeTaskDefinition = cast task.definition;

		// var commandArgs = getCommandArguments(definition.command, definition., true);

		// var vshaxe = getVshaxe();
		// var displayPort = vshaxe.displayPort;

		// if (vshaxe.enableCompilationServer && displayPort != null && commandArgs.indexOf("--connect") == -1)
		// {
		// 	commandArgs.push("--connect");
		// 	commandArgs.push(Std.string(displayPort));
		// }

		// // Resolve presentation or problem matcher?
		// // var problemMatchers = vshaxe.problemMatchers.get();
		// // var presentation = vshaxe.taskPresentation;

		// task.execution = new ShellExecution(limeExecutable + " " + commandArgs.join(" "),
		// 	{
		// 		cwd: workspace.workspaceFolders[0].uri.fsPath,
		// 		env: haxeEnvironment
		// 	});

		return task;
	}

	public function setTargetConfiguration(targetConfig:String):Void
	{
		context.workspaceState.update("lime.targetConfiguration", targetConfig);
		updateStatusBarItems();
		updateDisplayArguments();
	}

	private function updateDisplayArguments():Void
	{
		if (!hasProjectFile || !isProviderActive) return;

		var targetItem = getTargetItem();
		var commandLine = limeExecutable + " " + getCommandArguments("display", targetItem);
		commandLine = StringTools.replace(commandLine, "-verbose", "");

		ChildProcess.exec(commandLine, {cwd: workspace.workspaceFolders[0].uri.fsPath}, function(err, stdout:Buffer, stderror)
		{
			if (err != null && err.code != 0)
			{
				var message = 'Lime completion setup failed. Is the lime command available? Try running "lime setup" or changing the "lime.executable" setting.';
				var showFullErrorLabel = "Show Full Error";
				window.showErrorMessage(message, showFullErrorLabel).then(function(selection)
				{
					if (selection == showFullErrorLabel)
					{
						commands.executeCommand("workbench.action.toggleDevTools");
					}
				});
				trace(err);
			}
			else
			{
				displayArgumentsProvider.update(stdout.toString());
			}
		});
	}

	private function updateStatusBarItems():Void
	{
		if (hasProjectFile && isProviderActive)
		{
			var targetItem = getTargetItem();
			selectTargetItem.text = targetItem.label;
			selectTargetItem.show();
		}
		else
		{
			selectTargetItem.hide();
		}
	}

	private function updateTargetItems():Void
	{
		targetItems = [];
		var types = [null, "Debug", "Final"];

		for (i in 0...targets.length)
		{
			var target = targets[i];
			var targetLabel = targetLabels[i];

			for (type in types)
			{
				targetItems.push(
					{
						label: targetLabel + (type != null ? " / " + type : ""),
						description: "– " + target + (type != null ? " -" + type.toLowerCase() : ""),
						target: target,
						args: (type != null ? ["-" + type.toLowerCase()] : null)
					});
			}
		}

		var additionalConfigs = workspace.getConfiguration("lime").get("targetConfigurations", []);

		for (config in additionalConfigs)
		{
			if (config.target == null) continue;

			var target = config.target;
			var args:Array<String> = (config.args != null ? config.args : null);
			var command = target + (args != null ? " " + args.join(" ") : "");
			var label:String = (config.label != null ? config.label : command);

			targetItems.push(
				{
					label: label,
					description: "– " + command,
					target: target,
					args: args
				});
		}

		targetItems.sort(function(a, b)
		{
			if (a.label < b.label) return -1;
			return 1;
		});
	}

	// Event Handlers

	private function selectTargetItem_onCommand():Void
	{
		var items = targetItems.copy();
		var targetItem = getTargetItem();
		items.moveToStart(function(item) return item == targetItem);
		window.showQuickPick(items, {matchOnDescription: true, placeHolder: "Select Target Configuration"}).then(function(choice:TargetItem)
		{
			if (choice == null || choice == targetItem) return;
			setTargetConfiguration(choice.label);
		});
	}

	private function workspace_onDidChangeConfiguration(_):Void
	{
		refresh();
	}
}

@:enum private abstract LimeCommand(String) from String to String
{
	var CLEAN = "clean";
	var UPDATE = "update";
	var BUILD = "build";
	var RUN = "run";
	var TEST = "test";
}

private typedef LimeTaskDefinition =
{
	> TaskDefinition,
	var command:String;
	@:optional var target:String;
}

private typedef TargetItem =
{
	> QuickPickItem,
	var target:String;
	var args:Array<String>;
}
