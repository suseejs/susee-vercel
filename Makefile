SHELL := bash

.PHONY: dev build lint format init install profile


install:
		npm i
		bundle install
dev:
	JEKYLL_ENV=production bundle exec jekyll build
	bash scripts/mmcov.sh
build:
	JEKYLL_ENV=production bundle exec jekyll build
	bash scripts/mmcov.sh
format:
	bundle exec rufo .

lint:
	bundle exec rubocop

init:
	node scripts/init.mjs

profile:
	bundle exec jekyll build --profile