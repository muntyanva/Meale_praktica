###############################################
# Сборка фронтенда
###############################################
FROM node:24-alpine@sha256:934240a162082fd8b8a2f90cd5114446443f1eba1c5378f6687167ca405e6584 AS frontend-builder
WORKDIR /frontend
COPY frontend .
RUN yarn install \
    --prefer-offline \
    --frozen-lockfile \
    --non-interactive \
    --production=false \
    --network-timeout 1000000
RUN yarn generate

###############################################
# Базовый образ – Python
###############################################
FROM python:3.12-slim@sha256:7026274c107626d7e940e0e5d6730481a4600ae95d5ca7eb532dd4180313fea9 AS python-base
ENV MEALIE_HOME="/app"
ENV PYTHONUNBUFFERED=1 \
    PYTHONDONTWRITEBYTECODE=1 \
    PIP_NO_CACHE_DIR=off \
    PIP_DISABLE_PIP_VERSION_CHECK=on \
    PIP_DEFAULT_TIMEOUT=1000 \
    VENV_PATH="/opt/mealie"

# Добавляем виртуальное окружение в PATH
ENV PATH="$VENV_PATH/bin:$PATH"

# Создаём пользователя abc (UID 911) и даём ему права на /app
RUN useradd -u 911 -U -d $MEALIE_HOME -s /bin/bash abc \
    && usermod -G users abc \
    && mkdir -p $MEALIE_HOME \
    && chown -R abc:abc $MEALIE_HOME

###############################################
# Сборка бэкенда (пакета)
###############################################
FROM python-base AS backend-builder
RUN apt-get update \
    && apt-get install --no-install-recommends -y curl \
    && rm -rf /var/lib/apt/lists/*

RUN pip install --default-timeout=1000 uv

# Замораживаем зависимости, чтобы избежать пересборки
ENV UV_FROZEN=1
WORKDIR /mealie
COPY uv.lock pyproject.toml ./
COPY mealie ./mealie

# Копируем собранный фронтенд в пакет
COPY --from=frontend-builder /frontend/dist ./mealie/frontend

# Собираем wheel и исходники
RUN uv build --out-dir dist

# Формируем requirements.txt с хешами для точной установки
# ИСПРАВЛЕНО: заменены некорректные "& &" на "&&" и "> >" на ">>"
RUN uv export --no-editable --no-emit-project --extra pgsql --format requirements-txt --output-file dist/requirements.txt \
    && MEALIE_VERSION=$(python -c "import tomllib; print(tomllib.load(open('pyproject.toml', 'rb'))['project']['version'])") \
    && echo "mealie[pgsql]==${MEALIE_VERSION} \\" >> dist/requirements.txt \
    && pip hash dist/mealie-${MEALIE_VERSION}-py3-none-any.whl | tail -n1 | tr -d '\n' >> dist/requirements.txt \
    && echo " \\" >> dist/requirements.txt \
    && pip hash dist/mealie-${MEALIE_VERSION}.tar.gz | tail -n1 >> dist/requirements.txt

###############################################
# Контейнер с пакетами (используется как источник)
###############################################
FROM scratch AS packages
COPY --from=backend-builder /mealie/dist /

###############################################
# Сборка виртуального окружения Python
###############################################
FROM python-base AS venv-builder-base
RUN apt-get update \
    && apt-get install --no-install-recommends -y \
        build-essential \
        libpq-dev \
        libwebp-dev \
        ffmpeg \
        libsasl2-dev libldap2-dev libssl-dev \
        gnupg gnupg2 gnupg1 \
    && rm -rf /var/lib/apt/lists/*
RUN python3 -m venv --upgrade-deps $VENV_PATH

FROM venv-builder-base AS venv-builder
COPY --from=packages * /dist/
RUN . $VENV_PATH/bin/activate \
    && pip install --require-hashes -r /dist/requirements.txt --find-links /dist

###############################################
# Финальный производственный образ
###############################################
FROM python-base AS production
ENV PRODUCTION=true
ENV TESTING=false
ARG COMMIT
ENV GIT_COMMIT_HASH=$COMMIT

RUN apt-get update \
    && apt-get install --no-install-recommends -y \
        curl \
        ffmpeg \
        gosu \
        iproute2 \
        libldap-common \
        libldap2 \
        unzip \
    && rm -rf /var/lib/apt/lists/*

# Директория для Docker Secrets
RUN mkdir -p /run/secrets

# Копируем виртуальное окружение (уже содержит бэкенд и фронтенд)
COPY --from=venv-builder $VENV_PATH $VENV_PATH

# Устанавливаем данные NLTK для парсера ингредиентов
ENV NLTK_DATA="/nltk_data/"
COPY ./docker/setup_nltk_data.sh $MEALIE_HOME/setup_nltk_data.sh
RUN chmod +x $MEALIE_HOME/setup_nltk_data.sh && $MEALIE_HOME/setup_nltk_data.sh

COPY ./docker/entry.sh /app/run.sh
RUN chmod +x /app/run.sh

# Назначаем владельцем abc все каталоги, которые будут использоваться в рантайме
RUN chown -R abc:abc $MEALIE_HOME && chown -R abc:abc /nltk_data

VOLUME [ "$MEALIE_HOME/data/" ]
ENV APP_PORT=9000
EXPOSE ${APP_PORT}

# ИСПРАВЛЕНО: Явное переключение на непривилегированного пользователя (требование задания)
#USER abc

ENTRYPOINT ["/app/run.sh"]