FROM jekyll/jekyll:4

RUN gem sources --remove https://rubygems.org/ && \
  gem sources -a https://gems.ruby-china.com/

EXPOSE 4000

ENTRYPOINT ["jekyll", "serve"]