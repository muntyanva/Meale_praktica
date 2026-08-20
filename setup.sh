#!/bin/sh
# Скрипт автоматического развертывания Mealie с загрузкой тестовых данных
# Строго совместим с POSIX sh

# set -e # Раскомментируй, если хочешь жесткого прерывания при любой ошибке

echo "=========================================="
echo "Начало развертывания Mealie"
echo "=========================================="

# -----------------------------------------------------------------------------
# 1. Проверка наличия необходимых утилит
# -----------------------------------------------------------------------------
echo "[1/8] Проверка зависимостей..."
command -v docker >/dev/null 2>&1 || { echo >&2 "ОШИБКА: docker не установлен."; exit 1; }
command -v git >/dev/null 2>&1 || { echo >&2 "ОШИБКА: git не установлен."; exit 1; }
command -v openssl >/dev/null 2>&1 || { echo >&2 "ОШИБКА: openssl не установлен."; exit 1; }
command -v curl >/dev/null 2>&1 || { echo >&2 "ОШИБКА: curl не установлен."; exit 1; }
command -v jq >/dev/null 2>&1 || { echo >&2 "ОШИБКА: jq не установлен (нужен для обработки JSON). Установи: sudo apt install jq"; exit 1; }
echo "Все зависимости найдены."

# -----------------------------------------------------------------------------
# 2. Генерация .env файла (идемпотентно)
# -----------------------------------------------------------------------------
ENV_FILE=".env"
if [ ! -f "$ENV_FILE" ]; then
    echo "[2/8] Генерация файла .env со случайными паролями..."

    SECRET_KEY=$(openssl rand -hex 32)
    POSTGRES_PASSWORD=$(openssl rand -hex 16)
    REDIS_PASSWORD=$(openssl rand -hex 16)

    cat <<EOF > "$ENV_FILE"
MEALIE_EXTERNAL_PORT=9091

POSTGRES_USER=mealie
POSTGRES_PASSWORD=$POSTGRES_PASSWORD
POSTGRES_DB=mealie

REDIS_PASSWORD=$REDIS_PASSWORD

ALLOW_SIGNUP=false
LOG_LEVEL=info
BASE_URL=http://localhost:9091
SECRET=$SECRET_KEY
EOF

    echo "Файл .env успешно создан."
else
    echo "[2/8] Файл .env уже существует. Пропускаем генерацию (идемпотентность)."
fi

# -----------------------------------------------------------------------------
# 3. Сборка образов
# -----------------------------------------------------------------------------
echo "[3/8] Сборка образов (docker compose build)..."
docker compose build

# -----------------------------------------------------------------------------
# 4. Запуск контейнеров
# -----------------------------------------------------------------------------
echo "[4/8] Запуск контейнеров (docker compose up -d)..."
docker compose up -d

# -----------------------------------------------------------------------------
# 5. Ожидание готовности СУБД
# -----------------------------------------------------------------------------
echo "[5/8] Ожидание готовности базы данных..."
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

# Даем время для полной инициализации приложения и создания дефолтного пользователя
echo "  Дополнительное ожидание инициализации приложения..."
sleep 15

# -----------------------------------------------------------------------------
# 6. Получение API-токена и загрузка тестовых данных (НОВОЕ)
# -----------------------------------------------------------------------------
echo "[6/8] Получение API-токена для дефолтного пользователя..."
APP_PORT=$(grep '^MEALIE_EXTERNAL_PORT=' "$ENV_FILE" | cut -d '=' -f2-)
APP_PORT=${APP_PORT:-9091}

TOKEN_RESPONSE=$(curl -s -X POST "http://localhost:$APP_PORT/api/auth/token" \
    -H "Content-Type: application/x-www-form-urlencoded" \
    -d "username=changeme@example.com&password=MyPassword&grant_type=password")

# Извлекаем токен с помощью sed (POSIX-совместимый способ без jq для простого парсинга)
ACCESS_TOKEN=$(echo "$TOKEN_RESPONSE" | sed -n 's/.*"access_token":"\([^"]*\)".*/\1/p')

if [ -z "$ACCESS_TOKEN" ]; then
    echo "ОШИБКА: Не удалось получить токен."
    echo "Ответ сервера: $TOKEN_RESPONSE"
    echo "Рекомендация: проверь логи (docker compose logs mealie) или удали .env и volume для чистого старта."
    exit 1
fi
echo "✅ Токен успешно получен."

echo "[7/8] Загрузка тестовых рецептов..."
RECIPES="best-homemade-salsa-recipe.json bon-appetit.json chunky-apple-cake.json dairy-free-impossible-pumpkin-pie.json how-to-make-instant-pot-spaghetti.json instant-pot-chicken-and-potatoes.json"
BASE_GITHUB_URL="https://raw.githubusercontent.com/mealie-recipes/mealie/mealie-next/tests/data/json"

SUCCESS_COUNT=0
for FILE in $RECIPES; do
    echo "  ⏳ Обработка $FILE..."
    
    # Скачиваем JSON
    RECIPE_JSON=$(curl -s -L "$BASE_GITHUB_URL/$FILE")
    
    # Простая проверка, что мы получили валидный JSON (начинается с {)
    if [ -z "$RECIPE_JSON" ] || [ "$(echo "$RECIPE_JSON" | head -c 1)" != "{" ]; then
        echo "  ❌ Не удалось скачать или невалидный JSON для $FILE"
        continue
    fi

    # Создаем временный файл для пейлоада. 
    # Используем jq, чтобы безопасно экранировать JSON-строку внутри поля "data"
    TEMP_PAYLOAD=$(mktemp)
    jq --arg json_data "$RECIPE_JSON" -n '{includeTags: true, includeImages: true, data: $json_data}' > "$TEMP_PAYLOAD"

    # Отправляем запрос в API
    IMPORT_RESPONSE=$(curl -s -w "\n%{http_code}" -X POST "http://localhost:$APP_PORT/api/recipes/create/html-or-json" \
        -H "Authorization: Bearer $ACCESS_TOKEN" \
        -H "Content-Type: application/json" \
        -d @"$TEMP_PAYLOAD")

    HTTP_CODE=$(echo "$IMPORT_RESPONSE" | tail -n1)
    # BODY=$(echo "$IMPORT_RESPONSE" | sed '$d') # Можно раскомментировать для дебага

    if [ "$HTTP_CODE" = "200" ] || [ "$HTTP_CODE" = "201" ]; then
        echo "  ✅ Успешно импортирован"
        SUCCESS_COUNT=$((SUCCESS_COUNT + 1))
    else
        echo "  ❌ Ошибка $HTTP_CODE при импорте $FILE"
    fi
    
    # Чистим временный файл и делаем небольшую паузу, чтобы не спамить API
    rm -f "$TEMP_PAYLOAD"
    sleep 1
done

echo "  Импортировано рецептов: $SUCCESS_COUNT из $(echo $RECIPES | wc -w)"

# -----------------------------------------------------------------------------
# 8. Финальная проверка доступности
# -----------------------------------------------------------------------------
echo "[8/8] Финальная проверка доступности приложения..."

sleep 3
HTTP_CODE=$(curl -s -o /dev/null -w "%{http_code}" "http://localhost:$APP_PORT" || echo "000")

echo "=========================================="
echo "РАЗВЕРТЫВАНИЕ ЗАВЕРШЕНО!"
echo "=========================================="
echo "Адрес приложения: http://localhost:$APP_PORT"
echo "Логин по умолчанию: changeme@example.com"
echo "Пароль по умолчанию: MyPassword"
echo "Статус проверки (HTTP): $HTTP_CODE"

if [ "$HTTP_CODE" = "200" ] || [ "$HTTP_CODE" = "302" ] || [ "$HTTP_CODE" = "401" ]; then
    echo "Результат: УСПЕШНО. Приложение отвечает и готово к работе."
else
    echo "Результат: ВНИМАНИЕ. Неожиданный код ответа."
    echo "Рекомендуется проверить логи: docker compose logs mealie"
fi
echo "=========================================="