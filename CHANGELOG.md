# Changelog

## Unreleased — documentation and repository layout

- English and Russian README guides, SVG banner, menu preview and quick installation from GitHub.
- `docs/` guides for installation, Xray, operations, FAQ and verification limits.
- Released source and existing tests exposed in the repository, with a test guide and GitHub Actions workflow.
- Generated Xray examples and security/reporting documentation.
- Release builder includes documentation, tests and workflow files. Manager runtime remains version 1.0.0.

## 1.0.0 — 2026-11-23

- Автономный Bash-установщик с включённым исходным Python-кодом.
- Русскоязычное меню, CLI, профили YouTube и Telegram с независимыми пользователями, службами, портами и NFQUEUE.
- Установка apt-зависимостей и Zapret2 v1.0.7 с проверкой SHA256.
- Автоматический выбор свободных портов и очередей, защита чужих файлов и таблиц.
- Telegram TLS/MTProto и настраиваемый переход на порт 5222; отдельное обозначение UDP passthrough.
- Привязка Xray к явно выбранным инбаундам: PostgreSQL, SQLite, standalone JSON; горячее API и постоянное хранилище.
- Резервные копии, compare-and-swap, откат ошибок, защита незавершённых привязок от удаления профиля.
- Проверка SOCKS-выхода и неавторизованного MTProto; частичный результат отделён от полного.
- Управление жизненным циклом, обновление движка с dry-run и откатом, отключение привязок и полное удаление.
