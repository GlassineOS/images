# Probe: what survives BuildKit's exporters. Plants one of each thing a base must keep.
FROM alpine:3.24 AS a
RUN apk add -q libcap attr
FROM a AS b
RUN mkdir -p /p && cd /p \
 && echo cap > capfile && setcap cap_net_raw+ep capfile \
 && echo own > owned && chown 1234:5678 owned \
 && echo x > xattr && setfattr -n user.glassine -v probe xattr \
 && echo h > hard1 && ln hard1 hard2 \
 && ln -s /nowhere dangling \
 && mkdir sticky && chmod 1777 sticky \
 && echo s > suid && chmod 4755 suid \
 && mkfifo fifo
FROM b AS c
RUN echo layer3 > /p/later
FROM scratch AS copied
COPY --from=c / /
