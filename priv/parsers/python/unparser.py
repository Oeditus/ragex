#!/usr/bin/env python3
"""
Python AST Unparser for Metastatic

Converts AST JSON back to Python source code.
Uses ast.unparse() for Python 3.9+, with fallback for older versions.
"""

import ast
import json
import sys
from typing import Any, Dict


def dict_to_ast(data: Any) -> Any:
    """
    Convert JSON dictionary back to Python AST node.
    
    Args:
        data: Dictionary representation of AST or primitive value
        
    Returns:
        AST node or primitive value
    """
    if isinstance(data, dict) and '_type' in data:
        node_type = data['_type']
        
        # Get the AST node class
        node_class = getattr(ast, node_type, None)
        if node_class is None:
            raise ValueError(f"Unknown AST node type: {node_type}")
        
        # Prepare fields
        fields = {}
        for key, value in data.items():
            if key.startswith('_') or key in ['lineno', 'col_offset', 'end_lineno', 'end_col_offset']:
                continue
            
            if isinstance(value, list):
                fields[key] = [dict_to_ast(item) for item in value]
            else:
                fields[key] = dict_to_ast(value)
        
        # Create the node
        return node_class(**fields)
    elif isinstance(data, list):
        return [dict_to_ast(item) for item in data]
    else:
        # Primitive value
        return data


def unparse_ast(ast_dict: Dict[str, Any]) -> str:
    """
    Convert AST dictionary to Python source code.
    
    Args:
        ast_dict: Dictionary representation of Python AST
        
    Returns:
        Python source code as string
    """
    try:
        # Convert dict back to AST
        tree = dict_to_ast(ast_dict)
        
        # Use ast.unparse if available (Python 3.9+)
        if hasattr(ast, 'unparse'):
            source = ast.unparse(tree)
        else:
            # Fallback for older Python - use astor or basic repr
            try:
                import astor
                source = astor.to_source(tree)
            except ImportError:
                # Last resort - compile and decompile (lossy)
                source = compile(tree, '<string>', 'exec').__repr__()
        
        return source
    except Exception as e:
        raise ValueError(f"Failed to unparse AST: {e}")


def main():
    """Main entry point - read AST JSON from stdin, output source to stdout."""
    data = json.loads(sys.stdin.read())
    
    if not isinstance(data, dict) or '_type' not in data:
        print(json.dumps({
            'ok': False,
            'error': {
                'type': 'ValueError',
                'msg': 'Invalid AST format'
            }
        }))
        return
    
    try:
        source = unparse_ast(data)
        print(json.dumps({
            'ok': True,
            'source': source
        }))
    except Exception as e:
        print(json.dumps({
            'ok': False,
            'error': {
                'type': type(e).__name__,
                'msg': str(e)
            }
        }))


if __name__ == '__main__':
    main()
