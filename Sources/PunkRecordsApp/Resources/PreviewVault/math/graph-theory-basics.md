---
id: 22222222-2222-2222-2222-222222222222
title: Graph Theory Basics
tags: [math, graph-theory]
created: 2026-02-14
modified: 2026-03-15
---

# Graph Theory Basics

A graph **G = (V, E)** consists of a set of *vertices* (nodes) and *edges* (connections).

## Key Concepts

### Directed vs Undirected

- **Undirected**: edges have no direction — `A — B` means both can reach each other
- **Directed**: edges point one way — `A → B` doesn't imply `B → A`

Wikilinks in a knowledge base are **directed** but we compute backlinks to make them
effectively bidirectional.

### Degree

The **degree** of a node is the number of edges connected to it.

In a knowledge base:
- High out-degree = a note that links to many others (a *hub*)
- High in-degree = a note that many others reference (an *authority*)

### Paths and Cycles

A **path** is a sequence of edges connecting two nodes. A **cycle** is a path that
returns to its starting node.

```
A → B → C → A  (cycle of length 3)
```

## Applications to Knowledge Bases

| Graph Concept | KB Equivalent |
|---------------|---------------|
| Node | Note / Document |
| Edge | Wikilink |
| Degree | Number of links to/from a note |
| Connected component | Cluster of related notes |
| Isolated node | Orphan note (no links) |

See [[Swift Concurrency Deep Dive]] for practical applications of graph-like patterns in code.
See [[Quick Thoughts on Knowledge Graphs]] for the motivation behind graph-based PKM.
