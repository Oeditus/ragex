#!/usr/bin/env node
/**
 * JavaScript/TypeScript AST Parser for Metastatic
 * 
 * Parses JS/TS source code using @babel/parser and outputs AST as JSON.
 */

const fs = require('fs');
const path = require('path');
const os = require('os');

function requirePkg(name) {
  try {
    return require(name);
  } catch (err) {
    const candidates = [
      process.env.NODE_PATH,
      path.join(os.homedir(), '.local', 'share', 'mise', 'installs', 'node', 'latest', 'lib', 'node_modules'),
      path.resolve(__dirname, 'node_modules')
    ].filter(Boolean);

    for (const entry of candidates) {
      for (const dir of entry.split(path.delimiter)) {
        if (!dir) continue;
        try {
          return require(path.join(dir, name));
        } catch (_) {}
      }
    }
    throw err;
  }
}

const parser = requirePkg('@babel/parser');

function parseSource(source) {
  try {
    const ast = parser.parse(source, {
      sourceType: "module",
      allowImportExportEverywhere: true,
      allowReturnOutsideFunction: true,
      allowSuperOutsideMethod: true,
      allowUndeclaredExports: true,
      errorRecovery: true,
      plugins: [
        "typescript",
        "jsx",
        "classProperties",
        "classPrivateProperties",
        "classPrivateMethods",
        "decorators-legacy",
        "asyncGenerators",
        "exportDefaultFrom",
        "topLevelAwait"
      ]
    });

    return {
      ok: true,
      ast: ast
    };
  } catch (err) {
    return {
      ok: false,
      error: {
        type: err.name || 'SyntaxError',
        msg: err.message,
        lineno: err.loc ? err.loc.line : null,
        col: err.loc ? err.loc.column : null
      }
    };
  }
}

function main() {
  let source = '';
  if (process.argv.length > 2 && fs.existsSync(process.argv[2])) {
    source = fs.readFileSync(process.argv[2], 'utf-8');
  } else {
    source = fs.readFileSync(0, 'utf-8');
  }

  const result = parseSource(source);
  process.stdout.write(JSON.stringify(result));
}

main();
