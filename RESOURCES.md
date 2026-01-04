# Ragex MCP Resources

Resources provide read-only access to Ragex's internal state through the Model Context Protocol. They enable LLMs to observe and query Ragex's knowledge graph, embeddings cache, model configuration, and analysis results.

## Overview

Resources are accessed via URIs with the format: `ragex://<category>/<resource>`

All resources return JSON data with MIME type `application/json`.

## Available Resources

### 1. Graph Statistics (`ragex://graph/stats`)

Provides comprehensive statistics about the knowledge graph.

**Returns:**
```json
{
  "node_count": 1234,
  "node_counts_by_type": {
    "module": 150,
    "function": 1084
  },
  "edge_count": 2500,
  "average_degree": 2.03,
  "density": 0.0016,
  "top_by_pagerank": [
    {
      "node_id": "MyApp.Core.start/2",
      "pagerank_score": 0.015432
    }
  ],
  "top_by_degree": [
    {
      "node_id": "MyApp.Utils.log/1",
      "in_degree": 85,
      "out_degree": 3,
      "total_degree": 88
    }
  ]
}
```

**Use Cases:**
- Quick overview of codebase size and complexity
- Identify most important modules and functions
- Assess code connectivity and coupling

---

### 2. Cache Status (`ragex://cache/status`)

Reports on embedding cache health and file tracking status.

**Returns:**
```json
{
  "cache_enabled": true,
  "cache_file": "/home/user/.cache/ragex/project_abc123/embeddings.ets",
  "cache_size_bytes": 15728640,
  "cache_valid": true,
  "embeddings_count": 1234,
  "model_name": "all_mini_lm_l6_v2",
  "last_saved": 1704376800,
  "tracked_files": 45,
  "changed_files": 2,
  "unchanged_files": 43,
  "stale_entities_count": 8
}
```

**Use Cases:**
- Determine if cache refresh is needed
- Monitor embedding regeneration status
- Track file changes since last analysis

---

### 3. Model Configuration (`ragex://model/config`)

Returns active embedding model details and capabilities.

**Returns:**
```json
{
  "model_name": "sentence-transformers/all-MiniLM-L6-v2",
  "dimensions": 384,
  "ready": true,
  "memory_usage_mb": 400,
  "capabilities": {
    "supports_batch": true,
    "supports_normalization": true,
    "local_inference": true
  },
  "parameters": {
    "max_sequence_length": 512,
    "pooling": "mean"
  }
}
```

**Use Cases:**
- Verify model readiness before semantic operations
- Check model compatibility for cache migration
- Estimate resource requirements

---

### 4. Project Index (`ragex://project/index`)

Lists all tracked files with metadata and language distribution.

**Returns:**
```json
{
  "total_files": 45,
  "tracked_files": [
    {
      "path": "/project/lib/my_app/core.ex",
      "content_hash": "a1b2c3d4...",
      "analyzed_at": 1704376500,
      "size_bytes": 2048,
      "language": "elixir"
    }
  ],
  "language_distribution": {
    "elixir": 38,
    "python": 5,
    "javascript": 2
  },
  "recently_changed": ["/project/lib/my_app/utils.ex"],
  "changed_files_count": 2,
  "total_entities": 1234,
  "entities_by_type": {
    "modules": 150,
    "functions": 1084
  }
}
```

**Use Cases:**
- Discover all analyzed files in project
- Monitor file change activity
- Understand language composition

---

### 5. Algorithm Catalog (`ragex://algorithms/catalog`)

Comprehensive catalog of available graph algorithms with parameters and complexity.

**Returns:**
```json
{
  "algorithms": [
    {
      "name": "pagerank",
      "category": "centrality",
      "description": "Importance scoring based on call relationships",
      "parameters": {
        "damping": {
          "type": "float",
          "default": 0.85,
          "description": "Damping factor"
        },
        "max_iterations": {
          "type": "integer",
          "default": 100,
          "description": "Maximum iterations"
        }
      },
      "complexity": "O(k * (n + m)) where k is iterations, n is nodes, m is edges",
      "use_cases": [
        "Identify most important functions in codebase",
        "Find architectural entry points",
        "Prioritize refactoring efforts"
      ]
    }
  ]
}
```

**Algorithms Included:**
- **PageRank** - Importance scoring
- **Betweenness Centrality** - Bridge/bottleneck identification
- **Closeness Centrality** - Central function identification  
- **Degree Centrality** - Connection counting
- **Find Paths** - Call chain discovery
- **Detect Communities** - Architectural module discovery

**Use Cases:**
- Discover available algorithms and their parameters
- Understand complexity characteristics
- Select appropriate algorithm for analysis task

---

### 6. Analysis Summary (`ragex://analysis/summary`)

Pre-computed architectural analysis with key insights.

**Returns:**
```json
{
  "overview": {
    "total_nodes": 1234,
    "total_edges": 2500,
    "average_degree": 2.03,
    "density": 0.0016
  },
  "key_modules": [
    {
      "node_id": "MyApp.Core",
      "importance": 0.025
    }
  ],
  "bottlenecks": [
    {
      "node_id": "MyApp.Router.dispatch/2",
      "betweenness_score": 0.12
    }
  ],
  "communities": [
    {
      "community_id": "1",
      "size": 150,
      "sample_members": ["MyApp.Auth", "MyApp.Auth.Token", "MyApp.Auth.User"]
    }
  ],
  "community_count": 8
}
```

**Use Cases:**
- Quick architectural overview
- Identify critical functions and bottlenecks
- Understand code organization and modularity

---

## Usage Examples

### Via MCP Protocol

```json
{
  "jsonrpc": "2.0",
  "id": 1,
  "method": "resources/list",
  "params": {}
}
```

Response:
```json
{
  "jsonrpc": "2.0",
  "id": 1,
  "result": {
    "resources": [
      {
        "uri": "ragex://graph/stats",
        "name": "Graph Statistics",
        "description": "...",
        "mimeType": "application/json"
      }
    ]
  }
}
```

### Reading a Resource

```json
{
  "jsonrpc": "2.0",
  "id": 2,
  "method": "resources/read",
  "params": {
    "uri": "ragex://graph/stats"
  }
}
```

Response:
```json
{
  "jsonrpc": "2.0",
  "id": 2,
  "result": {
    "contents": [
      {
        "uri": "ragex://graph/stats",
        "mimeType": "application/json",
        "text": "{\"node_count\":1234,...}"
      }
    ]
  }
}
```

## Best Practices

1. **Cache Resources**: Results are computed on-demand but can be expensive for large codebases
2. **Check Model Readiness**: Query `model/config` before semantic operations
3. **Monitor Cache**: Use `cache/status` to decide when to refresh embeddings
4. **Combine Resources**: Use multiple resources together for comprehensive analysis

## Error Handling

Resources return errors in standard MCP format:

```json
{
  "jsonrpc": "2.0",
  "id": 1,
  "error": {
    "code": -32603,
    "message": "Internal error: Unknown resource: graph/invalid"
  }
}
```

**Common Errors:**
- Invalid URI scheme (must be `ragex://`)
- Unknown category or resource
- Resource computation failure (e.g., empty graph)

## Performance

| Resource | Typical Response Time | Notes |
|----------|----------------------|-------|
| `graph/stats` | 50-200ms | Depends on graph size |
| `cache/status` | <10ms | File system check |
| `model/config` | <5ms | In-memory data |
| `project/index` | 10-50ms | Depends on tracked files |
| `algorithms/catalog` | <5ms | Static data |
| `analysis/summary` | 200-1000ms | Runs community detection |

For large codebases (>10k entities), `analysis/summary` may take several seconds.

## See Also

- [PROMPTS.md](PROMPTS.md) - High-level workflow templates
- [ALGORITHMS.md](ALGORITHMS.md) - Detailed algorithm documentation
- [CONFIGURATION.md](CONFIGURATION.md) - Cache and model configuration
