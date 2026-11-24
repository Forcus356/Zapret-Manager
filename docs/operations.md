# Обслуживание

[К оглавлению](README.md) · [Установка](installation.md) · [FAQ](faq.md)

## Состояние и службы

```bash
sudo forcus-zapret status --profile all
sudo forcus-zapret logs --profile telegram --lines 80
sudo forcus-zapret restart --profile youtube --yes
sudo forcus-zapret stop --profile telegram --yes
sudo forcus-zapret start --profile telegram --yes
```

`status` отдельно показывает активность и автозапуск служб, SOCKS-порт, очередь, привязку Xray и сохранённый результат последней проверки. Открытие меню или `status` не запускает новую сетевую проверку.

Службы одного профиля:

```bash
systemctl status forcus-zapret-youtube-socks.service forcus-zapret-youtube-dpi.service --no-pager
journalctl -u forcus-zapret-youtube-dpi.service -n 100 --no-pager
```

Для Telegram замени `youtube` на `telegram`. Обычный restart профиля не требует перезапуска Xray.

## Проверка соединения

```bash
sudo forcus-zapret check --profile all
```

Проверяются прямой публичный IP и IP через SOCKS. Для YouTube выполняется HTTPS-запрос страницы; для Telegram — неавторизованный MTProto `req_pq_multi` с проверкой `resPQ` и nonce у пяти контрольных DC. Логин, чтение переписки и отправка сообщений не выполняются.

Частичная доступность DC отделяется от полного результата. Проверка SOCKS подтверждает прокси-часть цепочки, но не гарантирует, что конкретный VPN-инбаунд уже направлен в неё.

Для ручной проверки IP, если сохранились стандартные порты:

```bash
curl -4 -fsS --proxy socks5h://127.0.0.1:10808 https://api.ipify.org
curl -4 -fsS --proxy socks5h://127.0.0.1:10809 https://api.ipify.org
```

Сначала посмотри реальные порты в `status`. Для окончательной проверки подключись на устройстве через нужный VPN-профиль, проверь длинное видео, сообщения/медиа Telegram и отдельно звонок.

## Обновление движка Zapret2

```bash
sudo forcus-zapret update-engine --yes
```

Без дополнительных флагов используется закреплённая версия **v1.0.7** и её известная SHA256. Команда не ищет автоматически самый новый релиз и не обновляет сам менеджер.

Другая версия требует номера и проверенной SHA256 официального архива `zapret2-vX.Y.Z.tar.gz`:

```text
sudo forcus-zapret update-engine --engine-version vX.Y.Z --sha256 SHA256_ОФИЦИАЛЬНОГО_АРХИВА --yes
```

Это шаблон: перед запуском замени обе величины. Менеджер проверяет архив и стратегии всех установленных профилей через `--dry-run`, затем перезапускает DPI-службы. При ошибке запуска восстанавливаются прежние unit-файлы. Старые версии движка сохраняются до полного удаления менеджера.

## Обновление менеджера

Скачай опубликованный установщик заново и выполни установку нужных профилей:

```bash
curl -fsSL https://raw.githubusercontent.com/Forcus356/Zapret-Manager/main/install_forcus_zapret.sh -o /tmp/install_forcus_zapret.sh && sudo bash /tmp/install_forcus_zapret.sh install --profile both --yes
```

Повторная установка сохраняет настройки существующих профилей; `both` также установит отсутствующий профиль. Если используешь только один, укажи `--profile youtube` или `--profile telegram`. Команды `update` для самого менеджера в 1.0.0 нет.

## Резервная копия

```bash
sudo forcus-zapret backup --output /root/forcus-zapret-backup.tar.gz
```

Не размещай архив в публичном каталоге сайта или в Issues: состояние и конфигурации могут содержать данные инфраструктуры. Указанный выходной файл должен быть новым.

До изменяющих операций также создаются локальные копии в `/var/backups/forcus-zapret/`. Отдельной команды автоматического восстановления полного архива в 1.0.0 нет. Для ручного восстановления сначала сопоставь сохранённую конфигурацию с текущей, особенно при наличии более свежих правок панели.

## Файлы

| Путь | Содержимое |
|---|---|
| `/opt/forcus-zapret/` | Код менеджера и проверенные версии движка |
| `/usr/local/sbin/forcus-zapret` | Команда запуска |
| `/etc/forcus-zapret/state.json` | Профили, привязки, результаты проверок; root-only |
| `/etc/forcus-zapret/*.danted.conf` | Отдельные Dante-конфиги |
| `/etc/forcus-zapret/*.nft` | Правила собственных таблиц |
| `/etc/systemd/system/forcus-zapret-*.service` | Службы SOCKS и DPI |
| `/var/cache/forcus-zapret/` | Проверенные release-архивы |
| `/var/backups/forcus-zapret/` | Копии до изменений, шаблоны Xray до/после |

## Удаление одного профиля

```bash
sudo forcus-zapret xray detach --profile telegram --yes
sudo forcus-zapret remove --profile telegram --yes
```

Службы и таблица YouTube сохраняются. Если зарегистрированной привязки Telegram не было, отключать её не требуется; сначала проверь `status`.

## Полное удаление

```bash
sudo forcus-zapret xray detach --profile all --yes
sudo forcus-zapret uninstall --yes
```

Удаляются собственные службы, файлы и помеченные таблицы менеджера. Системные пакеты, резервные копии и чужие правила сохраняются; `nft flush ruleset` не выполняется. Глобальное значение conntrack accounting намеренно не обнуляется.

Удаление останавливается при зарегистрированных привязках или оставшихся обнаруженных ссылках на SOCKS в управляемом шаблоне. Другие программы и конфиги, куда SOCKS был добавлен вручную, нужно проверить отдельно.
