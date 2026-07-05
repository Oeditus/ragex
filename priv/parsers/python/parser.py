#!/usr/bin/env python3
"""
Python AST Parser for Metastatic

Parses Python source code and outputs AST as JSON for consumption by Elixir.
Uses only standard library (no external dependencies).
"""

import ast
import json
import sys
from typing import Any, Dict, List, Union


def ast_to_dict(node: Any) -> Union[Dict, List, Any]:
    """
    Convert Python AST node to JSON-serializable dictionary.
    
    Args:
        node: AST node or primitive value
        
    Returns:
        Dictionary representation of the AST node, or primitive value
    """
    if isinstance(node, ast.AST):
        result = {'_type': node.__class__.__name__}
        
        # Add line and column information if available
        if hasattr(node, 'lineno'):
            result['lineno'] = node.lineno
        if hasattr(node, 'col_offset'):
            result['col_offset'] = node.col_offset
        if hasattr(node, 'end_lineno'):
            result['end_lineno'] = node.end_lineno
        if hasattr(node, 'end_col_offset'):
            result['end_col_offset'] = node.end_col_offset
        
        # Convert all fields
        for field, value in ast.iter_fields(node):
            if isinstance(value, list):
                result[field] = [ast_to_dict(x) for x in value]
            else:
                result[field] = ast_to_dict(value)
        
        return result
    elif isinstance(node, list):
        return [ast_to_dict(x) for x in node]
    else:
        # Primitive values (strings, numbers, None, etc.)
        return node


def parse_source(source: str) -> Dict[str, Any]:
    """
    Parse Python source code to AST.
    
    Args:
        source: Python source code as string
        
    Returns:
        Dictionary with 'ok' status and 'ast' or 'error' field
    """
    try:
        tree = ast.parse(source)
        return {
            'ok': True,
            'ast': ast_to_dict(tree)
        }
    except SyntaxError as e:
        return {
            'ok': False,
            'error': {
                'type': 'SyntaxError',
                'msg': str(e.msg) if hasattr(e, 'msg') else str(e),
                'lineno': e.lineno,
                'offset': e.offset,
                'text': e.text
            }
        }
    except Exception as e:
        return {
            'ok': False,
            'error': {
                'type': type(e).__name__,
                'msg': str(e)
            }
        }


def main():
    """Main entry point - read source from stdin, output JSON to stdout."""
    source = sys.stdin.read()
    result = parse_source(source)
    print(json.dumps(result))


if __name__ == '__main__':
    main()
