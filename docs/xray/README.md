# Xray / 3x-ui

[К оглавлению](../README.md) · [Установка](../installation.md) · [Обслуживание](../operations.md)

Сначала установи нужные профили. Менеджер направляет выбранные назначения выбранных инбаундов в локальные SOCKS; остальную маршрутизацию сохраняет.

## Перед применением

- Найди реальные `tag` своих инбаундов. `ru-main` и `ru-youtube` ниже — заменяемые примеры.
- Проверь локальное API Xray: для горячей привязки нужны **HandlerService** и **RoutingService**, обычно `127.0.0.1:62789`.
- Убедись, что доступны бинарник Xray, его действующий runtime-конфиг и используемые geodata (`geosite:youtube`, `geosite:telegram`, `geoip:telegram`).
- Для доменных правил Xray должен получать домен от клиента или через sniffing на принимающем инбаунде.
- Xray и Dante должны использовать одно сетевое пространство: SOCKS слушает `127.0.0.1`. Для этой схемы с Docker используй host networking.

Если API или проверка конфига не проходят, профили могут остаться установленными, но маршрутизация не считается успешно применённой. Для ручной настройки можно экспортировать JSON.

## Автоматический backend

YouTube из двух инбаундов, Telegram только из одного:

```bash
sudo forcus-zapret xray apply \
  --backend auto \
  --youtube-inbounds ru-main,ru-youtube \
  --telegram-inbounds ru-main \
  --yes
```

Менеджер не выбирает все инбаунды автоматически. В меню они показываются списком, а область применения подтверждается отдельно для каждого сервиса.

## SQLite

Для 3x-ui с таблицей `settings` и ключом `xrayTemplateConfig`:

```bash
sudo forcus-zapret xray apply \
  --backend sqlite --config /etc/x-ui/x-ui.db \
  --youtube-inbounds ru-main --telegram-inbounds ru-main \
  --api 127.0.0.1:62789 --yes
```

## PostgreSQL

Для панели с тем же ключом `xrayTemplateConfig` в PostgreSQL:

```bash
sudo forcus-zapret xray apply \
  --backend postgres --database xui --pg-user postgres \
  --telegram-inbounds ru-main \
  --api 127.0.0.1:62789 --yes
```

Имя БД и пользователя замени своими. Локальный доступ PostgreSQL должен быть настроен заранее; не публикуй пароль в Issues или примерах команд.

## Standalone Xray

Здесь `--config` — настоящий постоянный JSON-файл, а `--runtime` — используемый действующим ядром конфиг:

```bash
sudo forcus-zapret xray apply \
  --backend standalone \
  --config /usr/local/etc/xray/config.json \
  --runtime /usr/local/etc/xray/config.json \
  --binary /usr/local/bin/xray \
  --api 127.0.0.1:62789 \
  --youtube-inbounds ru-main --telegram-inbounds ru-main --yes
```

Сгенерированный панелью `/usr/local/x-ui/bin/config.json` не заменяет постоянное хранилище 3x-ui. Для панели используй её backend, иначе следующая генерация может потерять изменения.

## Экспорт без применения

Фрагменты для установленных профилей и их фактических портов:

```bash
sudo forcus-zapret xray show \
  --youtube-inbounds ru-main --telegram-inbounds ru-main
```

Новый полный конфиг на основе существующего файла:

```bash
sudo forcus-zapret xray prepare \
  --input /root/xray-before.json \
  --output /root/xray-with-zapret.json \
  --youtube-inbounds ru-main --telegram-inbounds ru-main
```

`prepare` требует новый выходной файл, не перезаписывает исходный и не применяет конфиг. Полный результат содержит прежние клиентские данные: храни его с закрытыми правами.

### Готовые фрагменты

| Файл | Условия примера |
|---|---|
| [youtube-telegram.fragment.json](youtube-telegram.fragment.json) | Оба профиля, стандартные порты, Telegram без перевода порта |
| [youtube-telegram-5222.fragment.json](youtube-telegram-5222.fragment.json) | Те же профили с принудительным переводом подходящего MTProto на 5222 |
| [inbound-sniffing.fragment.json](inbound-sniffing.fragment.json) | Поле `sniffing` для существующего принимающего инбаунда |

Первые два фрагмента сгенерированы функцией `xray_fragment` текущего менеджера. Это **не полные конфиги**. Замени `ru-main`, проверь фактические SOCKS-порты и объедини массивы с существующими; не заменяй ими весь `outbounds` или `routing.rules`. В примерах предполагается уже существующий blackhole-outbound с тегом `blocked` для YouTube QUIC. Не добавляй дубли тегов.

Сниффинг настраивается внутри существующего инбаунда, а не отдельным входом:

```json
{
  "sniffing": {
    "enabled": true,
    "destOverride": ["http", "tls", "quic"],
    "routeOnly": true
  }
}
```

Доступность sniffing зависит от протокола и видимости имени. Скрытое/зашифрованное имя не всегда можно восстановить. Включение sniffing само по себе не меняет маршрут.

## Порядок правил

Первое совпадение выигрывает. Менеджер сохраняет чужие правила/outbounds, а новые правила вставляет после начальных служебных правил API, запрета private IP и исключения gstatic. Проверь, не перекрывает ли их более раннее широкое правило.

Для сложной схемы `xray apply` и `xray prepare` принимают `--insert-at N` — индекс вставки. Подбирай его по своему полному массиву правил, не копируй случайное число из чужой конфигурации.

Правила YouTube ограничены выбранными инбаундами и направлениями YouTube; UDP/443 для них блокируется ради TCP fallback. Telegram использует доменные и IP-правила. Если включён перевод на 5222, перед ним стоят TLS/HTTP-исключения, затем правила перевода и обычный проход Telegram.

## Применение и откат

Последовательность: резервная копия → проверка полного конфига Xray → добавление outbounds через API → применение полного routing → проверка отсутствия параллельной правки и запись постоянного шаблона → сохранение runtime.

Чужая параллельная правка шаблона не должна перезаписываться. При ошибке возвращаются прежние правила и удаляются добавленные обработчики; неполный откат сообщается отдельно. В таком случае сохрани вывод ошибки и проверь состояние перед повторной попыткой.

Отключить управляемую привязку:

```bash
sudo forcus-zapret xray detach --profile telegram --yes
```

Привязка YouTube и чужие правила сохраняются. Вручную настроенные потребители в других конфигах нужно отключать самостоятельно.
