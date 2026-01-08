# gptel-cpp-complete

[![MELPA](https://melpa.org/packages/gptel-cpp-complete-badge.svg)](https://melpa.org/#/gptel-cpp-complete)

`gptel-cpp-complete` is an experimental package that provides
**Copilot-style, context-aware C++ code completion** using:

- **eglot + clangd** for authoritative semantic information
- **tree-sitter** for correct current function retrieval
- **rg/ag** for repository-wide pattern retrieval
- **gptel** for LLM-powered code continuation
- **inline ghost text overlays** for a VS Code–like UX

Unlike generic AI assistants, this package is designed to behave like a
**language-server–style completion engine**, not a chat bot.
Its sole purpose is **accurate, minimal, inline code continuation**.

---

## Features

- Context-aware C++ code completion inside functions
- Uses *real* in-scope symbols from `clangd` (via `eglot`)
- Retrieves similar usage patterns from your repository with `rg/ag`
- Uses *real* call-hierarchy data from `clangd` (via `eglot`)
- Strict system prompt to avoid hallucinated APIs
- Inline “ghost text” suggestions
- Regenerates completion as you type (except when accepting with RET)
- Support both local and remote LLM with `gptel`

---

## Requirements

- Emacs 30+
- [`eglot/clangd`](https://github.com/joaotavora/eglot)
- [`tree-sitter`](https://github.com/tree-sitter/tree-sitter)
- [`gptel`](https://github.com/karthink/gptel)
- [`rg`](https://github.com/BurntSushi/ripgrep)
- [`ag`](https://github.com/ggreer/the_silver_searcher)

Recommended `eglot` configuration:
```emacs lisp
(use-package eglot
   :ensure t
   :hook (((c-mode c++-mode c-ts-mode c++-ts-mode) . eglot-ensure))
   :init
   (setq eglot-stay-out-of '(imenu)
         read-process-output-max (* 1024 1024) ; 1MB
         eglot-autoshutdown t
         eglot-events-buffer-size 0
         eglot-send-changes-idle-time 0.5)
   :config
   (add-to-list 'eglot-server-programs
                '((c-mode c-ts-mode c++-mode c++-ts-mode objc-mode)
                  . ("clangd"
                     "--compile-commands-dir=./build/"
                     "--background-index"
                     "--clang-tidy"
                     "--completion-style=detailed"
                     "--header-insertion=never"
                     "--pch-storage=memory"
                     "--malloc-trim"))))
```

Recommended `tree-sitter` configuration:
```emacs lisp
 (when (treesit-available-p)
   (use-package treesit
     :ensure t
     :init (setq treesit-extra-load-path
                 (gptel-cpp-complete--get-treesit-extra-load-path)
                 major-mode-remap-alist
                 '((c-mode          . c-ts-mode)
                   (c++-mode        . c++-ts-mode))
                 treesit-font-lock-level 4)))
```

Recommended `gptel` configuration:
```emacs lisp
(use-package gptel
   :ensure t
   :config
   (setq gptel-model 'deepseek-ai/DeepSeek-V3.2
         ;; Randomness in response text, 0 to 2
         gptel-temperature 0
         gptel-backend
         ;; free 2000 request per-day, each model 500
         (gptel-make-openai "Free"
           :host "api-inference.modelscope.cn"
           :stream t
           :key ""
           :models '(Qwen/Qwen2.5-32B-Instruct
                     deepseek-ai/DeepSeek-V3.2))))
```

---

## Installation

Clone the repository and add it to your load path:

```emacs lisp
(add-to-list 'load-path "/path/to/gptel-cpp-complete")
(require 'gptel-cpp-complete)
(when (display-graphic-p)
  ;; gptel-cpp-complete-mode not work well in terminal mode
  (dolist (c-mode-hook '(c-mode-common-hook c-ts-mode-hook c++-ts-mode-hook))
    (add-hook c-mode-hook #'gptel-cpp-complete-mode)))
```

---

## Screenshots

![demo.gif](demo.gif)

---

## Contributing
Yes, please do! See [CONTRIBUTING](CONTRIBUTING.md) for guidelines.

---

## License

See [LICENSE](LICENSE). Copyright (c) 2025 Huming Chen <chenhuming@gmail.com>
