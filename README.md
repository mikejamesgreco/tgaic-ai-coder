# TGAIC AI Coder

**The Greco AI Coder**

A lightweight, local-first AI coding assistant powered by **llama.cpp** and **GGUF** models, with a browser UI, local model management, and built-in Hugging Face model discovery.

> **Run useful coding models on your own hardware.**

## Run TGAIC

TGAIC is designed primarily as a local application rather than a hosted inference service.

Open the standalone browser application directly from disk:

```text
tgaic-ai-coder.html
```

The local runtime is:

```text
TGAIC HTML (file://)
        │
        ▼
PowerShell Bridge
127.0.0.1:8787
        │
        ▼
llama-server / llama.cpp
127.0.0.1:8080
        │
        ▼
Local GGUF model cache
C:\Models
```

The browser owns the user interface and conversation history. The PowerShell bridge provides the browser-safe localhost/CORS boundary plus model-management and Hugging Face helper endpoints. `llama-server` performs model loading and inference.

---

## Features

- Local OpenAI-compatible chat through `llama-server`
- llama.cpp router-mode model discovery
- Load and unload cached models from the browser
- Hugging Face GGUF model discovery
- Result-oriented pagination that continues through Hub results until a logical TGAIC page is filled
- Hugging Face API-supported global sort choices
- Quantization and GGUF-size filters
- Text/multimodal repository filtering
- `mmproj` and MTP companion-file detection
- Advisory model-compatibility hints
- Optional Hugging Face token authentication
- Safe Markdown rendering for assistant responses
- Fenced code blocks with language labels and Copy buttons
- Streaming local responses
- Local conversation history for the current browser page/session
- No JavaScript framework or CDN dependency

---

## Windows Setup

### 1. Install llama.cpp

```bat
winget install llama.cpp
```

Open a new Command Prompt if Winget updates `PATH`, then verify:

```bat
llama-server --version
where llama-server
```

### 2. Establish the TGAIC model cache

```bat
set LLAMA_CACHE=C:\Models
```

### 3. Download/cache a GGUF model

For example:

```bat
llama-server -hf Qwen/Qwen2.5-Coder-3B-Instruct-GGUF:Q4_K_M
```

Wait for the download and model load to complete, then stop it with `Ctrl+C`.

### 4. Start llama.cpp in router mode

```bat
set LLAMA_CACHE=C:\Models
llama-server --host 127.0.0.1 --port 8080 -c 8192
```

Router mode intentionally has no `-hf` or `-m` model on the startup command.

### 5. Start the TGAIC bridge

```bat
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\tgaic-ai-coder-bridge-v0025.ps1
```

Expected endpoints:

```text
Bridge:       http://127.0.0.1:8787/
llama-server: http://127.0.0.1:8080/
TGAIC API:    http://127.0.0.1:8787/v1
```

### 6. Open TGAIC

Double-click `tgaic-ai-coder.html`, leave the endpoint as `http://127.0.0.1:8787/v1`, click **Connect**, then **Refresh Models** and **Load Selected** as needed.

---

## Model Cache Workflow

```text
Discover model
      │
      ▼
set LLAMA_CACHE=C:\Models
      │
      ▼
llama-server -hf user/repository:quant
      │
      ▼
download + verify model loads
      │
      ▼
Ctrl+C
      │
      ▼
restart generic router mode
      │
      ▼
Refresh Models
      │
      ▼
Load Selected
      │
      ▼
Chat
```

A GGUF file does **not** necessarily have to fit entirely in GPU VRAM. llama.cpp can offload some work to the GPU and use CPU/system RAM for the remainder. In testing, a roughly 3.4 GB / 6B-class coder/reasoning GGUF ran successfully on a machine with only 2 GB of GPU VRAM.

Model file size is therefore a practical discovery signal, not a hard VRAM limit.

---

## Hugging Face Model Browser

TGAIC can search Hugging Face through the local bridge.

Searches do not run automatically when filter controls change. Click **Search Models** when ready.

The bridge:

1. Searches the Hugging Face model API.
2. Prefilters likely GGUF repositories.
3. Inspects repository trees for exact GGUF files and sizes.
4. Applies quantization, size, and model-type filters.
5. Detects companion files such as `mmproj` and MTP sidecars.
6. Continues through Hub result pages until the requested TGAIC page is filled or the Hub search is exhausted.

Sort options shown in TGAIC are limited to sort keys supported by the Hugging Face model API, so the sort affects the global Hub traversal order rather than only reordering one local page.

### Hugging Face token

An optional token can be entered in the HTML page or supplied to the bridge:

```bat
set HF_TOKEN=hf_your_token_here
```

The HTML token is sent only to the local bridge in the `X-HF-Token` header. TGAIC does not persist it in localStorage, sessionStorage, cookies, or a file.

---

## Compatibility Notes

A repository containing a `.gguf` file is not automatically guaranteed to load in the installed llama.cpp build.

TGAIC's compatibility column is advisory. It can identify repository traits such as text GGUFs, multimodal repositories with `mmproj`, optional MTP sidecars, and newer-model-family warnings.

The definitive compatibility check is still whether llama.cpp successfully loads the exact GGUF conversion.

On Windows, this warning may appear:

```text
failed to create symlink: A required privilege is not held by the client
switching to degraded mode
```

If llama.cpp continues after it, the warning itself is not necessarily fatal. Look for the subsequent model-load error or success message.

---

## Markdown Rendering

Assistant responses are rendered locally as safe Markdown, including headings, emphasis, lists, inline/fenced code, blockquotes, links, horizontal rules, basic tables, language labels, and Copy buttons.

Model-produced HTML is escaped rather than executed.

---

## Internet Access

The local GGUF model itself does not browse the Internet.

Current network behavior is deliberately narrow:

- Local chat/model traffic: localhost only
- Hugging Face Model Browser: contacts Hugging Face only when the user explicitly runs a model search

General web search, arbitrary URL fetching/scraping, autonomous browser tools, image generation, and reference-file/RAG tooling are future capabilities rather than current TGAIC features.

---

## Repository Structure

```text
tgaic-ai-coder/
│
├── index.html                         # GitHub Pages launcher
├── tgaic-ai-coder.html               # Standalone browser application
├── tgaic-ai-coder-bridge-v0025.ps1   # Local bridge
├── README.md
├── .gitignore
├── CHANGELOG.md                       # Optional/recommended
├── screenshot.jpeg                    # Optional GitHub/SFLA preview
└── LICENSE                            # Repository license
```

---

## Privacy

Chat inference runs through local `127.0.0.1` endpoints and the selected local GGUF model.

The Hugging Face browser is the current intentional external-network feature. A model search sends the search/filter request to Hugging Face through the bridge. A Hugging Face token, when used, is not intended to be logged or persisted by TGAIC.

---

## Project

**Repository:** https://github.com/mikejamesgreco/tgaic-ai-coder

**GitHub Pages:** https://mikejamesgreco.github.io/tgaic-ai-coder/

---

## Author

**Michael J. Greco**

TGAIC — **The Greco AI Coder**

© mikejamesgreco.me LLC. All rights reserved.
