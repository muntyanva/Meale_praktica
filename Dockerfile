# ============================================
# Стадия 1: Сборка фронтенда (Node.js)
# ============================================
FROM node:24-alpine AS frontend-builder

WORKDIR /frontend

COPY frontend/package.json frontend/yarn.lock ./
RUN yarn install --frozen-lockfile --non-interactive --network-timeout 1000000

COPY frontend .
RUN yarn generate

# ============================================
# Стадия 2: Базовый образ Python (Alpine)
# ============================================
FROM python:3.12-alpine AS python-base

ENV MEALIE_HOME="/app" \
    PYTHONUNBUFFERED=1 \
    PYTHONDONTWRITEBYTECODE=1 \
    PIP_NO_CACHE_DIR=off \
    PIP_DISABLE_PIP_VERSION_CHECK=on \
    PIP_DEFAULT_TIMEOUT=100 \
    VENV_PATH="/opt/mealie"

ENV PATH="$VENV_PATH/bin:$PATH"

# Создаём пользователя abc (UID 911) – именно его ожидает entry.sh
RUN adduser -D -u 911 abc && \
    mkdir -p $MEALIE_HOME && \
    chown abc:abc $MEALIE_HOME

# ============================================
# Стадия 3: Сборка бэкенд-пакета (uv)
# ============================================
FROM python-base AS backend-builder

RUN apk add --no-cache \
    curl \
    build-base \
    libpq-dev \
    libwebp-dev \
    ffmpeg \
    openldap-dev \
    openssl-dev \
    libsasl-dev \
    linux-headers

RUN pip install uv
ENV UV_FROZEN=1

WORKDIR /mealie

COPY uv.lock pyproject.toml ./
COPY mealie ./mealie
COPY --from=frontend-builder /frontend/dist ./mealie/frontend

RUN uv build --out-dir dist

RUN uv export --no-editable --no-emit-project --extra pgsql --format requirements-txt --output-file dist/requirements.txt && \
    MEALIE_VERSION=$(python -c "import tomllib; print(tomllib.load(open('pyproject.toml', 'rb'))['project']['version'])") && \
    echo "mealie[pgsql]==${MEALIE_VERSION} \\" >> dist/requirements.txt && \
    pip hash dist/mealie-${MEALIE_VERSION}-py3-none-any.whl | tail -n1 | tr -d '\n' >> dist/requirements.txt && \
    echo " \\" >> dist/requirements.txt && \
    pip hash dist/mealie-${MEALIE_VERSION}.tar.gz | tail -n1 >> dist/requirements.txt

# ============================================
# Стадия 4: Пакеты (scratch)
# ============================================
FROM scratch AS packages
COPY --from=backend-builder /mealie/dist /

# ============================================
# Стадия 5: Сборка виртуального окружения (без инструментов сборки)
# ============================================
FROM python-base AS venv-builder

RUN apk add --no-cache \
    libpq \
    libwebp \
    ffmpeg \
    openldap \
    curl

RUN python -m venv --upgrade-deps $VENV_PATH

COPY --from=packages / /dist/

RUN . $VENV_PATH/bin/activate && \
    pip install --require-hashes -r /dist/requirements.txt --find-links /dist

# ============================================
# Стадия 6: Финальный образ (production)
# ============================================
FROM python-base AS production

ENV PRODUCTION=true \
    TESTING=false \
    NLTK_DATA="/nltk_data/" \
    APP_PORT=9000 \
    HOST=0.0.0.0

ARG COMMIT
ENV GIT_COMMIT_HASH=$COMMIT

# Устанавливаем только рантайм-пакеты
RUN apk add --no-cache \
    curl \
    ffmpeg \
    gosu \
    iproute2 \
    openldap \
    libpq \
    libwebp \
    unzip \
    tzdata

RUN mkdir -p /run/secrets

# Копируем виртуальное окружение
COPY --from=venv-builder $VENV_PATH $VENV_PATH

# Копируем скрипты из docker/
COPY docker/ /tmp/docker/
RUN cp /tmp/docker/setup_nltk_data.sh $MEALIE_HOME/ && \
    cp /tmp/docker/healthcheck.sh $MEALIE_HOME/ && \
    cp /tmp/docker/entry.sh $MEALIE_HOME/run.sh && \
    chmod +x $MEALIE_HOME/*.sh && \
    rm -rf /tmp/docker

# Устанавливаем NLTK-данные
RUN $MEALIE_HOME/setup_nltk_data.sh

# Назначаем владельцем abc (скрипт entry.sh ожидает этого пользователя)
RUN chown -R abc:abc $MEALIE_HOME $VENV_PATH /nltk_data

VOLUME [ "$MEALIE_HOME/data/" ]
EXPOSE ${APP_PORT}

# Healthcheck
HEALTHCHECK --interval=30s --timeout=10s --start-period=5s --retries=3 \
    CMD $MEALIE_HOME/healthcheck.sh

# НЕ переключаемся на abc здесь – entry.sh сделает это через gosu
# USER abc  <-- не добавляем

ENTRYPOINT ["/app/run.sh"]

LABEL org.opencontainers.image.source="https://github.com/mealie-recipes/mealie" \
      org.opencontainers.image.version="${COMMIT}" \
      org.opencontainers.image.description="Mealie - Recipe Manager"
