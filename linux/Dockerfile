# Imagen Linux minima para verificar disponibilidad de puertos TCP.
FROM alpine:3.20

# bash  -> necesario para /dev/tcp
# netcat-openbsd -> herramienta auxiliar de diagnostico dentro del contenedor
RUN apk add --no-cache bash netcat-openbsd tzdata

ENV TARGET_HOST=127.0.0.1 \
    PORT_CHECK_TIMEOUT=3

COPY check_port.sh /usr/local/bin/check_port.sh
RUN chmod +x /usr/local/bin/check_port.sh

# El script devuelve el codigo de salida (0 abierto / 1 cerrado), que es lo que
# ve docker run; por eso el entrypoint es el propio script.
ENTRYPOINT ["/usr/local/bin/check_port.sh"]
CMD ["--help"]
