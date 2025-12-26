# gptel-cpp-complete

`gptel-cpp-complete` is an experimental package that provides
**Copilot-style, context-aware C++ code completion** using:

- **eglot + clangd** for authoritative semantic information
- **ag (the_silver_searcher)** for repository-wide pattern retrieval
- **gptel** for LLM-powered code continuation
- **inline ghost text overlays** for a VS Code–like UX

Unlike generic AI assistants, this package is designed to behave like a
**language-server–style completion engine**, not a chat bot.

---

## Features

- Context-aware C++ code completion inside functions
- Uses *real* in-scope symbols from `clangd` (via LSP completion)
- Retrieves similar usage patterns from your repository with `ag`
- Strict system prompt to avoid hallucinated APIs
- Inline “ghost text” suggestions
- Regenerates completion as you type (except when accepting with RET)
- Fully local-LLM friendly (no cloud dependency required)

---

## Non-goals

This package intentionally does **not** try to:

- Replace `company-mode` or standard LSP completion
- Explain code or provide chat-style answers
- Invent new APIs, helpers, or abstractions
- Perform whole-project reasoning in a single request

Its sole purpose is **accurate, minimal, inline code continuation**.

---

## Requirements

- Emacs 28+ (Emacs 29+ recommended)
- [`eglot`](https://elpa.gnu.org/packages/eglot.html)
- [`gptel`](https://github.com/karthink/gptel)
- [`ag`](https://github.com/ggreer/the_silver_searcher)
- `clangd` with background indexing enabled

Recommended `clangd` invocation:

```bash
clangd --background-index --clang-tidy

## Installation
Manual

Clone the repository and add it to your load path:

(add-to-list 'load-path "/path/to/gptel-cpp-complete")
(require 'gptel-cpp-complete)
