# Документация / Documentation

[English overview](../README.md) · [Главная на русском](../README.ru_RU.md)

Подробные руководства ниже написаны на русском; команды CLI одинаковы для всех языков.

## Начать работу

| Руководство | Что внутри |
|---|---|
| [Установка](installation.md) | Требования, мастер, CLI, Telegram 5222 и совместимость |
| [Xray / 3x-ui](xray/README.md) | Выбор инбаундов, backend, API, sniffing и готовые JSON-фрагменты |
| [Обслуживание](operations.md) | Проверки, журналы, обновление, копии, файлы и удаление |
| [Частые вопросы](faq.md) | Что проверять, если службы работают, а сервис — нет |

## Проверки и исходники

- [Отчёт о проверках релиза 1.0.0](testing.md).
- [Запуск тестов и устройство набора](../tests/README.md).
- [История изменений](../CHANGELOG.md).
- [Безопасность](../SECURITY.ru_RU.md) / [Security](../SECURITY.md).
- [Сторонние компоненты](../THIRD_PARTY_NOTICES.md).

## Примеры

- [Консольное меню — текст](assets/menu-demo.txt), [иллюстрация](assets/menu-preview.svg).
- [YouTube + Telegram, режим порта Telegram off](xray/youtube-telegram.fragment.json).
- [YouTube + Telegram, принудительный MTProto 5222](xray/youtube-telegram-5222.fragment.json).
- [Sniffing для существующего инбаунда](xray/inbound-sniffing.fragment.json).

JSON-фрагменты — примеры с тегом `ru-main` и стандартными портами. Они не являются полными конфигами Xray. Для действующих настроек используй `forcus-zapret xray show`.
