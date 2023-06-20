import axios from 'axios';
import path = require('path/posix');
import * as vscode from 'vscode';

class XDefinitionProvider implements vscode.DefinitionProvider {
	async provideDefinition(
		document: vscode.TextDocument,
		position: vscode.Position,
		token: vscode.CancellationToken
	): Promise<vscode.Definition> {
		let range = document.getWordRangeAtPosition(position);
		let word = document.getText(range);

		console.log(word);

		if (vscode.workspace.workspaceFolders) {
			let workspaceFolder = vscode.workspace.workspaceFolders[0];
			let workspacePath = workspaceFolder.uri.fsPath;
			let docPath = document.uri.fsPath;
			let res = await axios.post('http://localhost:8080/definition', {
				workDir: workspacePath,
				file: docPath,
				word: word
			});
			let data = res.data.srcSpan;

			let filePath = data.sourceSpanFileName;
			let fileUri = vscode.Uri.file(path.join(workspacePath, path.normalize(filePath)));

			let line = data.sourceSpanStartLine - 1; // 0-based line number
			let character = data.sourceSpanStartColumn - 1; // 0-based character position
			let definitionPosition = new vscode.Position(line, character);
			let definitionLocation = new vscode.Location(fileUri, definitionPosition);

			console.log(filePath);

			return Promise.resolve(definitionLocation);
		}

		let definitionPosition = new vscode.Position(position.line, position.character);
		let definitionLocation = new vscode.Location(document.uri, definitionPosition);
		return Promise.resolve(definitionLocation);
	}
}

export function activate(context: vscode.ExtensionContext) {
	console.log('Congratulations, your extension "hs-gtd" is now active!');
	let disposable = vscode.commands.registerCommand('hs-gtd.helloWorld', () => {
		vscode.window.showInformationMessage('Hello World from hs-gtd!');
	});

	context.subscriptions.push(
		vscode.languages.registerDefinitionProvider(
			{ scheme: 'file', language: 'haskell' },
			new XDefinitionProvider()
		)
	);

	context.subscriptions.push(disposable);
}

// This method is called when your extension is deactivated
export function deactivate() { }
