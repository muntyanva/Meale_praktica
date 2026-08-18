#!/bin/sh
# Скрипт автоматического развертывания Mealie
# Строго совместим с POSIX sh (dash, ash, sh)

set -e  # Останавливать выполнение при любой ошибке

echo "=========================================="
echo "Начало развертывания Mealie"
echo "=========================================="

# -----------------------------------------------------------------------------
# 1. Проверка наличия необходимых утилит
# -----------------------------------------------------------------------------
echo "[1/6] Проверка зависимостей..."
command -v docker >/dev/null 2>&1 || { echo >&2 "ОШИБКА: docker не установлен."; exit 1; }
command -v git >/dev/null 2>&1 || { echo >&2 "ОШИБКА: git не установлен."; exit 1; }
command -v openssl >/dev/null 2>&1 || { echo >&2 "ОШИБКА: openssl не установлен."; exit 1; }
command -v curl >/dev/null 2>&1 || { echo >&2 "ОШИБКА: curl не установлен."; exit 1; }
echo "Все зависимости найдены."

# -----------------------------------------------------------------------------
# 2. Генерация .env файла (идемпотентно)
# -----------------------------------------------------------------------------
ENV_FILE=".env"
if [ ! -f "$ENV_FILE" ]; then
    echo "[2/6] Генерация файла .env со случайными паролями..."

    SECRET_KEY=$(openssl rand -hex 32)
    POSTGRES_PASSWORD=$(openssl rand -hex 16)
    REDIS_PASSWORD=$(openssl rand -hex 16)

    cat <<EOF > "$ENV_FILE"
# Mealie Environment Variables

# Порт, на котором будет доступно приложение на хосте
MEALIE_EXTERNAL_PORT=9091

# База данных
POSTGRES_USER=mealie
POSTGRES_PASSWORD=$POSTGRES_PASSWORD
POSTGRES_DB=mealie

# Redis
REDIS_PASSWORD=$REDIS_PASSWORD

# Mealie
ALLOW_SIGNUP=false
LOG_LEVEL=info
BASE_URL=http://localhost:9091
SECRET=$SECRET_KEY

# (Опционально) Учётные данные администратора по умолчанию
DEFAULT_EMAIL=admin@example.com
DEFAULT_PASSWORD=Mealie123!
EOF

    echo "Файл .env успешно создан."
else
    echo "[2/6] Файл .env уже существует. Пропускаем генерацию (идемпотентность)."
fi

# -----------------------------------------------------------------------------
# 3. Сборка образов (docker compose build)
# -----------------------------------------------------------------------------
echo "[3/6] Сборка образов (docker compose build)..."
docker compose build

# -----------------------------------------------------------------------------
# 4. Запуск контейнеров
# -----------------------------------------------------------------------------
echo "[4/6] Запуск контейнеров (docker compose up -d)..."
docker compose up -d

# -----------------------------------------------------------------------------
# 5. Ожидание готовности СУБД
# -----------------------------------------------------------------------------
echo "[5/6] Ожидание готовности базы данных..."
MAX_RETRIES=30
RETRY_COUNT=0
HEALTH_STATUS="starting"

while [ $RETRY_COUNT -lt $MAX_RETRIES ]; do
    HEALTH_STATUS=$(docker inspect --format='{{.State.Health.Status}}' mealie-postgres 2>/dev/null || echo "not_found")

    if [ "$HEALTH_STATUS" = "healthy" ]; then
        echo "База данных успешно прошла проверку готовности!"
        break
    fi

    echo "  Ожидание... (попытка $((RETRY_COUNT + 1))/$MAX_RETRIES, статус: $HEALTH_STATUS)"
    sleep 3
    RETRY_COUNT=$((RETRY_COUNT + 1))
done

if [ "$HEALTH_STATUS" != "healthy" ]; then
    echo "ОШИБКА: База данных не стала доступной за отведенное время."
    docker compose logs postgres
    exit 1
fi

# -----------------------------------------------------------------------------
# 6. Итоговый статус и проверка доступности
# -----------------------------------------------------------------------------
echo "[6/6] Финальная проверка доступности приложения..."

# Читаем порт из .env (если не задан, используем 9091)
APP_PORT=$(grep '^MEALIE_EXTERNAL_PORT=' "$ENV_FILE" | cut -d '=' -f2-)
APP_PORT=${APP_PORT:-9091}

# Даём пару секунд на окончательную инициализацию
sleep 5

HTTP_CODE=$(curl -s -o /dev/null -w "%{http_code}" "http://localhost:$APP_PORT" || echo "000")

echo "=========================================="
echo "РАЗВЕРТЫВАНИЕ ЗАВЕРШЕНО!"
echo "=========================================="
echo "Адрес приложения: http://localhost:$APP_PORT"
echo "Логин по умолчанию: admin@example.com"
echo "Пароль по умолчанию: Mealie123!"
echo "Статус проверки (HTTP): $HTTP_CODE"

if [ "$HTTP_CODE" = "200" ] || [ "$HTTP_CODE" = "302" ] || [ "$HTTP_CODE" = "401" ]; then
    echo "Результат: УСПЕШНО. Приложение отвечает."
else
    echo "Результат: ВНИМАНИЕ. Неожиданный код ответа."
    echo "Рекомендуется проверить логи: docker compose logs mealie"
fi
echo "=========================================="
