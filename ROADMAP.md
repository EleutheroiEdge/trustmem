# Roadmap

## Near-term

- Add provider-level embedding split support:
  - `indexModel` for write/index operations
  - `queryModel` for retrieval/search operations
- Add explicit guardrail error when a dual-mode model is configured in a single-model path.
- Add MCP server command wiring (`trustmem mcp serve`) for Cursor/Claude Desktop.

## NVIDIA embedding note

For `nv-embedqa-e5-v5`, correct routing is:
- index: `nvidia/nv-embedqa-e5-v5-passage`
- query: `nvidia/nv-embedqa-e5-v5-query`

Single-model embedding paths should not silently run this model in production.
