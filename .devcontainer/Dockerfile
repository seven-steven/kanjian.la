FROM jekyll/jekyll:4.2.0

RUN \
  apk add --no-cache openssh-client
# gem sources --remove https://rubygems.org/ && \
# gem sources -a https://gems.ruby-china.com/ && \
# gem sources -u && \
# bundle config mirror.https://rubygems.org https://gems.ruby-china.com

EXPOSE 4000

ENTRYPOINT ["bundle", "exec", "jekyll", "serve"]