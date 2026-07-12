const fs = require('fs');
const parser = require('@babel/parser');

function walk(node, callback, parent = null, currentClass = null) {
  if (!node) return;

  let nextClass = currentClass;
  if (node.type === 'ClassDeclaration' || node.type === 'ClassExpression') {
    nextClass = node.id ? node.id.name : 'AnonymousClass';
  }

  callback(node, parent, currentClass);

  for (const key in node) {
    if (key === 'loc' || key === 'start' || key === 'end' || key === 'leadingComments' || key === 'trailingComments') continue;
    const child = node[key];
    if (child && typeof child === 'object') {
      if (Array.isArray(child)) {
        child.forEach(c => walk(c, callback, node, nextClass));
      } else if (child.type) {
        walk(child, callback, node, nextClass);
      }
    }
  }
}

function analyze(code) {
  try {
    const ast = parser.parse(code, {
      sourceType: 'module',
      plugins: ['typescript', 'jsx', 'classProperties', 'decorators-legacy', 'dynamicImport']
    });

    const result = {
      modules: [],
      functions: [],
      calls: [],
      imports: []
    };

    walk(ast, (node, parent, currentClass) => {
      // 1. Classes -> Modules
      if (node.type === 'ClassDeclaration' || node.type === 'ClassExpression') {
        const name = node.id ? node.id.name : 'AnonymousClass';
        result.modules.push({
          name: name,
          line: node.loc ? node.loc.start.line : 1,
          doc: extractDocstring(node)
        });
      }

      // 2. Functions
      if (node.type === 'FunctionDeclaration') {
        const name = node.id ? node.id.name : 'anonymous';
        result.functions.push({
          name: name,
          arity: node.params.length,
          module: currentClass || '__main__',
          line: node.loc ? node.loc.start.line : 1,
          doc: extractDocstring(node),
          visibility: name.startsWith('_') ? 'private' : 'public'
        });
      } else if (node.type === 'FunctionExpression' || node.type === 'ArrowFunctionExpression') {
        // Check if assigned to a variable, e.g. const foo = () => {}
        if (parent && parent.type === 'VariableDeclarator' && parent.id && parent.id.name) {
          const name = parent.id.name;
          result.functions.push({
            name: name,
            arity: node.params.length,
            module: currentClass || '__main__',
            line: node.loc ? node.loc.start.line : 1,
            doc: extractDocstring(parent),
            visibility: name.startsWith('_') ? 'private' : 'public',
            arrow: node.type === 'ArrowFunctionExpression'
          });
        }
      } else if (node.type === 'ClassMethod' || node.type === 'TSDeclareFunction') {
        const name = node.key ? (node.key.name || node.key.value) : null;
        if (name) {
          result.functions.push({
            name: name,
            arity: node.params ? node.params.length : 0,
            module: currentClass || '__main__',
            line: node.loc ? node.loc.start.line : 1,
            doc: extractDocstring(node),
            visibility: name.startsWith('_') ? 'private' : 'public'
          });
        }
      }

      // 3. Imports
      if (node.type === 'ImportDeclaration') {
        if (node.source && node.source.value) {
          result.imports.push({
            to_module: node.source.value,
            type: 'import',
            line: node.loc ? node.loc.start.line : 1
          });
        }
      } else if (node.type === 'CallExpression' && node.callee && node.callee.name === 'require') {
        if (node.arguments && node.arguments[0] && typeof node.arguments[0].value === 'string') {
          result.imports.push({
            to_module: node.arguments[0].value,
            type: 'require',
            line: node.loc ? node.loc.start.line : 1
          });
        }
      }

      // 4. Calls
      if (node.type === 'CallExpression') {
        // Skip keywords that are not actually calls (though Babel distinguishes calls from control flow,
        // we can still verify)
        if (node.callee.type === 'Identifier') {
          const func = node.callee.name;
          if (!['if', 'for', 'while', 'switch', 'catch', 'return'].includes(func)) {
            result.calls.push({
              to_function: func,
              to_module: null,
              line: node.loc ? node.loc.start.line : 1
            });
          }
        } else if (node.callee.type === 'MemberExpression') {
          const obj = node.callee.object.name || (node.callee.object.id && node.callee.object.id.name) || null;
          const prop = node.callee.property.name || node.callee.property.value || null;
          if (prop) {
            result.calls.push({
              to_function: prop,
              to_module: obj,
              line: node.loc ? node.loc.start.line : 1
            });
          }
        }
      }
    });

    return result;
  } catch (e) {
    return { error: e.message };
  }
}

function extractDocstring(node) {
  if (node.leadingComments && node.leadingComments.length > 0) {
    return node.leadingComments.map(c => c.value.trim()).join('\n');
  }
  return null;
}

// Read stdin
const code = fs.readFileSync(0, 'utf-8');
const result = analyze(code);
console.log(JSON.stringify(result));
