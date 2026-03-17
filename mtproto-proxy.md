# MTProto Proxy для Telegram

Установка MTProto прокси с поддержкой **канала спонсора** на существующий VPN-сервер.

## Что это даёт

- Пользователи подключаются к Telegram через ваш прокси **по одной ссылке**
- В списке чатов у них появляется **ваш канал** (реклама)
- Работает параллельно с VLESS VPN на том же сервере
- Нагрузка минимальна — 200-300 пользователей на 1GB RAM

## Требования

- Существующий VPN-сервер (после установки `install-vpn.sh`)
- Аккаунт Telegram для получения AD_TAG

## Шаг 1: Получите AD_TAG

1. Откройте [@MTProxybot](https://t.me/MTProxybot) в Telegram
2. Отправьте `/newproxy`
3. Введите `IP_СЕРВЕРА:8443` (порт 8443, т.к. 443 занят VPN)
4. Бот выдаст **AD_TAG** — сохраните его
5. Привяжите свой канал через бота

## Шаг 2: Установка на сервер

Подключитесь к серверу:

```bash
ssh root@IP_СЕРВЕРА
```

Выполните команды:

```bash
# Генерация секретного ключа (случайный)
SECRET=$(head -c 16 /dev/urandom | xxd -ps)
echo "Ваш SECRET: $SECRET"

# Открыть порт в файрволе
ufw allow 8443/tcp comment 'MTProto Proxy'

# Запуск через Docker (официальный образ Telegram)
docker run -d \
  --name=mtproto-proxy \
  --restart=always \
  -p 8443:443 \
  -e SECRET=$SECRET \
  -e TAG=ВАШ_AD_TAG \
  -v mtproto-config:/data \
  telegrammessenger/proxy:latest
```

> Замените `ВАШ_AD_TAG` на тег из @MTProxybot.

### Если Docker не установлен

```bash
curl -fsSL https://get.docker.com | sh
```

## Шаг 3: Проверка

```bash
# Статус контейнера
docker ps | grep mtproto

# Логи
docker logs mtproto-proxy --tail 20
```

## Шаг 4: Ссылка для пользователей

Формат ссылки:

```
https://t.me/proxy?server=IP_СЕРВЕРА&port=8443&secret=SECRET
```

Или в формате `tg://`:

```
tg://proxy?server=IP_СЕРВЕРА&port=8443&secret=SECRET
```

Пользователь нажимает ссылку → Telegram предлагает подключить прокси → в чатах появляется ваш канал.

## Управление

```bash
# Остановить
docker stop mtproto-proxy

# Запустить
docker start mtproto-proxy

# Перезапустить
docker restart mtproto-proxy

# Удалить полностью
docker rm -f mtproto-proxy
```

## Смена секретного ключа

```bash
NEW_SECRET=$(head -c 16 /dev/urandom | xxd -ps)
docker rm -f mtproto-proxy
docker run -d \
  --name=mtproto-proxy \
  --restart=always \
  -p 8443:443 \
  -e SECRET=$NEW_SECRET \
  -e TAG=ВАШ_AD_TAG \
  -v mtproto-config:/data \
  telegrammessenger/proxy:latest
echo "Новый SECRET: $NEW_SECRET"
```

Не забудьте обновить ссылку для пользователей.

## FAQ

**Порт 443 занят VPN, почему 8443?**
VLESS Reality слушает на 443. MTProto работает на 8443, Telegram поддерживает любой порт.

**Сколько трафика потребляет?**
~50-200 МБ/день на активного пользователя. На безлимитном сервере — не проблема.

**Можно ли без канала спонсора?**
Да, просто не указывайте `-e TAG=...` при запуске.

**Прокси перестал работать?**
```bash
docker restart mtproto-proxy
docker logs mtproto-proxy --tail 50
```
