# Advanced Refactor MCP Tool

This document describes the `advanced_refactor` MCP tool added in Phase 10A.7, which exposes 8 sophisticated refactoring operations via the Model Context Protocol.

## Overview

The `advanced_refactor` tool provides AST-aware, atomic refactoring operations for Elixir codebases. All operations:
- Use AST manipulation for precision
- Integrate with the knowledge graph for cross-file updates
- Support atomic transactions with automatic rollback
- Include optional syntax validation and formatting
- Return structured results with detailed operation metadata

## Phase 10A Implementation Status

**Fully Working Operations (6/8):**
- Inline Function: Replace all calls with function body
- Convert Visibility: Toggle between `def` and `defp`
- Rename Parameter: Rename parameter within function scope
- Modify Attributes: Add/remove/update module attributes
- Change Signature: Add/remove/reorder/rename parameters with call site updates
- Extract Function: Basic support for simple cases without variable dependencies

**Deferred Operations (2/8):**
- Move Function: Requires advanced semantic analysis
- Extract Module: Requires advanced semantic analysis

**Limitations:**
- Extract Function does not yet handle variable assignment tracking or return value inference
- Move Function and Extract Module require cross-module refactoring infrastructure
- 12 tests are currently skipped (marked with `@tag skip: true, reason: :phase_10a`)

All working operations are production-ready with comprehensive test coverage.

## Tool Definition

```json
{
  "name": "advanced_refactor",
  "description": "Advanced refactoring operations: extract_function, inline_function, convert_visibility, rename_parameter, modify_attributes, change_signature, move_function, extract_module",
  "inputSchema": {
    "type": "object",
    "properties": {
      "operation": {
        "type": "string",
        "description": "Type of advanced refactoring operation",
        "enum": [
          "extract_function",
          "inline_function",
          "convert_visibility",
          "rename_parameter",
          "modify_attributes",
          "change_signature",
          "move_function",
          "extract_module"
        ]
      },
      "params": {
        "type": "object",
        "description": "Operation-specific parameters"
      },
      "validate": {
        "type": "boolean",
        "description": "Validate before and after refactoring",
        "default": true
      },
      "format": {
        "type": "boolean",
        "description": "Format code after refactoring",
        "default": true
      },
      "scope": {
        "type": "string",
        "description": "Refactoring scope (for applicable operations)",
        "enum": ["module", "project"],
        "default": "project"
      }
    },
    "required": ["operation", "params"]
  }
}
```

## Operations

### 1. Extract Function [BASIC SUPPORT]

Extracts a range of lines from a function into a new function, with automatic free variable analysis and parameter inference.

**Status:** Basic support only. Works for simple cases without variable assignments. Variable assignment tracking, return value inference, and guard handling are deferred.

**Parameters:**
```json
{
  "operation": "extract_function",
  "params": {
    "module": "MyModule",
    "source_function": "process_data",
    "source_arity": 2,
    "new_function": "validate_input",
    "line_start": 45,
    "line_end": 52,
    "placement": "before"  // optional: "before" or "after" (default: "after")
  },
  "validate": true,
  "format": true
}
```

**Success Response:**
```json
{
  "status": "success",
  "operation": "extract_function",
  "files_modified": 1,
  "details": {
    "module": "MyModule",
    "source_function": "process_data",
    "new_function": "validate_input",
    "line_range": [45, 52]
  }
}
```

### 2. Inline Function [FULLY WORKING]

Replaces all calls to a function with its body, with parameter substitution. Removes the function definition.

**Status:** Fully functional and production-ready.

**Parameters:**
```json
{
  "operation": "inline_function",
  "params": {
    "module": "MyModule",
    "function": "helper",
    "arity": 1
  },
  "validate": true,
  "format": true,
  "scope": "project"  // "module" or "project"
}
```

**Success Response:**
```json
{
  "status": "success",
  "operation": "inline_function",
  "files_modified": 1,
  "details": {
    "module": "MyModule",
    "function": "helper",
    "arity": 1
  }
}
```

### 3. Convert Visibility [FULLY WORKING]

Converts a function between public (`def`) and private (`defp`).

**Status:** Fully functional and production-ready.

**Parameters:**
```json
{
  "operation": "convert_visibility",
  "params": {
    "module": "MyModule",
    "function": "process",
    "arity": 2,
    "visibility": "private"  // "public" or "private"
  },
  "validate": true,
  "format": true
}
```

**Success Response:**
```json
{
  "status": "success",
  "operation": "convert_visibility",
  "files_modified": 1,
  "details": {
    "module": "MyModule",
    "function": "process",
    "arity": 2,
    "visibility": "private"
  }
}
```

### 4. Rename Parameter [FULLY WORKING]

Renames a parameter within a function's scope (all clauses and body).

**Status:** Fully functional and production-ready.

**Parameters:**
```json
{
  "operation": "rename_parameter",
  "params": {
    "module": "MyModule",
    "function": "process",
    "arity": 2,
    "old_param": "data",
    "new_param": "input"
  },
  "validate": true,
  "format": true
}
```

**Success Response:**
```json
{
  "status": "success",
  "operation": "rename_parameter",
  "files_modified": 1,
  "details": {
    "module": "MyModule",
    "function": "process",
    "arity": 2,
    "old_param": "data",
    "new_param": "input"
  }
}
```

### 5. Modify Attributes [FULLY WORKING]

Adds, removes, or updates module attributes (`@moduledoc`, `@doc`, `@spec`, custom attributes).

**Status:** Fully functional and production-ready.

**Parameters:**
```json
{
  "operation": "modify_attributes",
  "params": {
    "module": "MyModule",
    "changes": [
      {
        "action": "add",
        "name": "behaviour",
        "value": "GenServer"
      },
      {
        "action": "update",
        "name": "moduledoc",
        "value": "Updated documentation"
      },
      {
        "action": "remove",
        "name": "deprecated"
      }
    ]
  },
  "validate": true,
  "format": true
}
```

**Attribute Change Actions:**
- `add`: Add new attribute (error if exists)
- `update`: Update existing attribute (error if doesn't exist)
- `remove`: Remove attribute (error if doesn't exist)

**Success Response:**
```json
{
  "status": "success",
  "operation": "modify_attributes",
  "files_modified": 1,
  "details": {
    "module": "MyModule",
    "changes_count": 3
  }
}
```

### 6. Change Signature [FULLY WORKING]

Changes a function's signature by adding, removing, reordering, or renaming parameters. Updates all call sites.

**Status:** Fully functional and production-ready. Includes validation to prevent removing parameters still used in function bodies.

**Parameters:**
```json
{
  "operation": "change_signature",
  "params": {
    "module": "MyModule",
    "function": "process",
    "old_arity": 2,
    "changes": [
      {
        "action": "add",
        "name": "opts",
        "position": 2,
        "default": "[]"  // optional
      },
      {
        "action": "remove",
        "position": 0
      },
      {
        "action": "reorder",
        "from": 1,
        "to": 0
      },
      {
        "action": "rename",
        "position": 0,
        "new_name": "input"
      }
    ]
  },
  "validate": true,
  "format": true,
  "scope": "project"
}
```

**Signature Change Actions:**
- `add`: Add parameter at position (with optional default)
- `remove`: Remove parameter at position
- `reorder`: Move parameter from one position to another
- `rename`: Rename parameter at position

**Success Response:**
```json
{
  "status": "success",
  "operation": "change_signature",
  "files_modified": 3,
  "details": {
    "module": "MyModule",
    "function": "process",
    "old_arity": 2,
    "changes_count": 4
  }
}
```

### 7. Move Function [DEFERRED]

Moves a function from one module to another, updating all references.

**Status:** Implementation deferred pending advanced semantic analysis infrastructure.

**Parameters:**
```json
{
  "operation": "move_function",
  "params": {
    "source_module": "MyModule",
    "target_module": "MyModule.Helpers",  // can be new or existing
    "function": "helper",
    "arity": 1
  },
  "validate": true,
  "format": true,
  "scope": "project"
}
```

**Success Response:**
```json
{
  "status": "success",
  "operation": "move_function",
  "files_modified": 2,
  "details": {
    "source_module": "MyModule",
    "target_module": "MyModule.Helpers",
    "function": "helper",
    "arity": 1
  }
}
```

### 8. Extract Module [DEFERRED]

Extracts multiple functions from a module into a new module, creating the file and updating references.

**Status:** Implementation deferred pending advanced semantic analysis infrastructure.

**Parameters:**
```json
{
  "operation": "extract_module",
  "params": {
    "source_module": "MyModule",
    "new_module": "MyModule.Validators",
    "functions": [
      {"name": "validate_email", "arity": 1},
      {"name": "validate_phone", "arity": 1},
      {"name": "validate_address", "arity": 1}
    ]
  },
  "validate": true,
  "format": true,
  "scope": "project"
}
```

**Success Response:**
```json
{
  "status": "success",
  "operation": "extract_module",
  "files_modified": 2,
  "details": {
    "source_module": "MyModule",
    "new_module": "MyModule.Validators",
    "functions_count": 3
  }
}
```

## Error Responses

All operations return structured errors on failure:

```json
{
  "type": "refactor_error",
  "operation": "extract_function",
  "message": "Refactoring failed",
  "files_modified": 2,
  "rolled_back": true,
  "errors": [
    {
      "path": "lib/my_module.ex",
      "reason": "Syntax error on line 45"
    }
  ]
}
```

## Common Options

### validate (boolean, default: true)
- When `true`, validates syntax before applying changes and after
- Validation uses language-specific parsers (Elixir: `Code.string_to_quoted/1`)
- Recommended to keep enabled for safety

### format (boolean, default: true)
- When `true`, runs code formatter after refactoring
- Uses project-specific formatter (`mix format`, `rebar3 fmt`, etc.)
- Helps maintain code style consistency

### scope (string, default: "project")
- `"module"`: Only refactor within the module file
- `"project"`: Refactor across all files in the knowledge graph
- Not all operations support module scope (e.g., move_function always requires project scope)

## Integration with Knowledge Graph

All operations leverage the knowledge graph to:
- Find all call sites across the project
- Detect dependencies and references
- Update imports and aliases
- Track which files need modification

The graph must be populated (via `analyze_directory` or `analyze_file`) before refactoring.

## Transaction Safety

All operations use atomic transactions:
1. Backups created for all affected files
2. Changes applied atomically
3. Validation performed
4. On any error, all changes rolled back
5. Backups retained for manual recovery

## Best Practices

1. **Analyze First**: Run `analyze_directory` before refactoring to populate the knowledge graph
2. **Enable Validation**: Keep `validate: true` to catch syntax errors early
3. **Use Formatting**: Keep `format: true` to maintain code style
4. **Project Scope**: Use `scope: "project"` for operations that affect call sites
5. **Test After**: Run tests after refactoring to verify correctness
6. **Commit Often**: Commit before and after refactoring for easy recovery

## Examples

### Example 1: Extract Complex Validation Logic

```json
{
  "operation": "extract_function",
  "params": {
    "module": "UserController",
    "source_function": "create_user",
    "source_arity": 2,
    "new_function": "validate_user_params",
    "line_start": 23,
    "line_end": 45,
    "placement": "before"
  }
}
```

### Example 2: Make Internal Helper Public

```json
{
  "operation": "convert_visibility",
  "params": {
    "module": "Utils",
    "function": "parse_date",
    "arity": 1,
    "visibility": "public"
  }
}
```

### Example 3: Add Options Parameter to Function

```json
{
  "operation": "change_signature",
  "params": {
    "module": "DataProcessor",
    "function": "process",
    "old_arity": 1,
    "changes": [
      {
        "action": "add",
        "name": "opts",
        "position": 1,
        "default": "[]"
      }
    ]
  },
  "scope": "project"
}
```

### Example 4: Reorganize Module Structure

```json
{
  "operation": "extract_module",
  "params": {
    "source_module": "User",
    "new_module": "User.Validators",
    "functions": [
      {"name": "validate_email", "arity": 1},
      {"name": "validate_password", "arity": 1},
      {"name": "validate_age", "arity": 1}
    ]
  }
}
```

## Implementation Details

- **File**: `lib/ragex/mcp/handlers/tools.ex`
- **Handler Function**: `advanced_refactor_tool/1`
- **Backend**: `lib/ragex/editor/refactor.ex` (public API)
- **Elixir Implementation**: `lib/ragex/editor/refactor/elixir.ex`
- **Lines Added**: ~500 (MCP integration + parameter parsing)

## Testing

Test the tool using the MCP protocol:

```bash
# Via MCP client
echo '{
  "jsonrpc": "2.0",
  "id": 1,
  "method": "tools/call",
  "params": {
    "name": "advanced_refactor",
    "arguments": {
      "operation": "extract_function",
      "params": { ... }
    }
  }
}' | ragex mcp
```

## Future Enhancements

**Phase 10A Completion:**
- Variable assignment tracking for extract_function
- Return value inference for extract_function
- Guard handling in extracted functions
- Move Function implementation (cross-module refactoring)
- Extract Module implementation (multi-function extraction)

**Phase 10B: Multi-Language Support**
- Multi-language support (Erlang, Python, JavaScript)
- Cross-language refactoring via Metastatic integration

**Phase 10C: Preview/Safety (COMPLETED)**
- [x] Preview/dry-run mode with diff generation
- [x] Conflict detection and resolution
- [x] Undo/redo stack
- [x] Refactoring reports and visualization

## See Also

- `REFACTORING.md` - Comprehensive refactoring guide
- `REFACTORING_API.md` - Low-level API reference
- `PHASE10_COMPLETE.md` - Phase 10 completion summary
- `WARP.md` - Project development guide
