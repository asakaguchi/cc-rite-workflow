# Pre-check List — Retired

> **Status: Fully retired.** Item 0 (routing dispatcher) と Items 1-3 (state checks) は、`create.md` が `create-interview.md` 等の sub-skill chain に delegation していた時代の Pre-check list 設計を前提とした記述。flat workflow 統合により sub-skill chain が無くなったため、本 reference の routing dispatcher と grep-based state check には **active caller が存在しない**。
>
> sub-skill chain を再導入する場合は、本 reference の 4 grep pattern 設計 (`grep -F` / `grep -E` / character-class 誤解釈警告 / sentinel 形式) を canonical な参照として再採用すること。
