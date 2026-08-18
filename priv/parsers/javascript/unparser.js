#!/usr/bin/env node
/**
 * JavaScript/TypeScript AST Unparser for Metastatic
 * 
 * Converts Babel AST JSON back to JS/TS source code using @babel/generator.
 */

const fs = require('fs');
const generate = require('@babel/generator').default;

function unparseAst(ast) {
  try {
    const output = generate(ast, {
      retainLines: false,
      compact: false,
      jsescOption: { quotes: 'double' }
    });

    return {
      ok: true,
      source: output.code
    };
  } catch (err) {
    return {
      ok: false,
      error: {
        type: err.name || 'Error',
        msg: err.message
      }
    };
  }
}

function main() {
  let jsonStr = '';
  if (process.argv.length > 2 && fs.existsSync(process.argv[2])) {
    jsonStr = fs.readFileSync(process.argv[2], 'utf-8');
  } else {
    jsonStr = fs.readFileSync(0, 'utf-8');
  }

  let data;
  try {
    data = JSON.parse(jsonStr);
  } catch (err) {
    process.stdout.write(JSON.stringify({
      ok: false,
      error: {
        type: 'ValueError',
        msg: 'Invalid AST JSON: ' + err.message
      }
    }));
    return;
  }

  let astNode = data;
  if (data && typeof data === 'object' && data.ok === true && data.ast) {
    astNode = data.ast;
  }

  const result = unparseAst(astNode);
  process.stdout.write(JSON.stringify(result));
}

main();
