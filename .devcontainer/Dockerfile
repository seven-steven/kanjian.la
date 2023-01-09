FROM ruby:3.1.3-slim

RUN sed -i "s@http://\(deb\|security\).debian.org@http://mirrors.aliyun.com@g" /etc/apt/sources.list && \
  apt-get update && \
  apt-get install -y --no-install-recommends git && \
  gem sources --remove https://rubygems.org/ && \
  gem sources -a https://gems.ruby-china.com/ && \
  gem sources -u && \
  gem install bundler && \
  bundle config mirror.https:///rubygems.org https://gems.ruby-china.com && \
  gem install jekyll -v 3.9.1

EXPOSE 4000

ENTRYPOINT ["bundle", "exec", "jekyll", "serve"]