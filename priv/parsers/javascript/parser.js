#!/usr/bin/env node
/**
 * JavaScript/TypeScript AST Parser for Metastatic
 * 
 * Parses JS/TS source code using @babel/parser and outputs AST as JSON.
 */

const fs = require('fs');
const parser = require('@babel/parser');

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
