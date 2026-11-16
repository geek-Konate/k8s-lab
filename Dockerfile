
# Image Nginx non-root
FROM docker.io/nginxinc/nginx-unprivileged:mainline-alpine

# Privilèges temporaires pour installer les correctifs
USER root

# Mise à jour des packages Alpine
RUN apk upgrade --no-cache

# Retour à un utilisateur non privilégié
USER 101:101

EXPOSE 8080
