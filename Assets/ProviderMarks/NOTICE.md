# Provider marks

These SVGs come from [Lobe Icons](https://github.com/lobehub/lobe-icons) (`@lobehub/icons-static-svg`
1.101.0, MIT). They're the `-color` variants of the Claude, Codex, Zhipu (GLM), DeepSeek, MiniMax and
Kimi icons. Changes from the originals:
- the `<svg>` root is normalised to a 24×24 box and `<title>` is removed;
- in `kimi.svg` and `kimi-dark.svg`, `currentColor` is replaced with black and white respectively.

The marks and names belong to Anthropic, OpenAI, Zhipu AI, DeepSeek, MiniMax and Moonshot AI. They
are used only to show which provider's usage is on screen. Including them doesn't imply
affiliation, sponsorship or endorsement.

`Sources/AIUsage/ProviderIcons.swift` is generated from these files by `Scripts/embed_marks.py`.
