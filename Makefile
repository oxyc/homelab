.PHONY: help lint validate compose-config up homekit down deps check

help:           ## Show this help
	@grep -E '^[a-z-]+:.*?## ' $(MAKEFILE_LIST) | awk -F':.*?## ' '{printf "  %-14s %s\n", $$1, $$2}'

deps:           ## Install ansible collections
	cd ansible && ansible-galaxy collection install -r requirements.yml

hooks:          ## Install the local git pre-commit hook
	git config core.hooksPath .githooks
	@echo "git hooks installed (.githooks/)"

lint:           ## yamllint + ansible-lint
	yamllint .
	cd ansible && ansible-lint

compose-config: ## Validate docker compose (needs docker/.env)
	cd docker && docker compose config -q && echo "compose OK"
	cd docker && docker compose --profile homekit config -q && echo "compose (homekit) OK"

test:           ## Prove the HomeKit toggle (docker only, no ansible)
	./scripts/test-toggle.sh

preflight:      ## Full local rehearsal (lint + syntax + compose + caddy + toggle)
	./scripts/preflight.sh

molecule:       ## Run the docker_host role molecule test (needs molecule[docker])
	cd ansible/roles/docker_host && molecule test

validate: lint compose-config test  ## All static checks

check:          ## Ansible dry-run against inventory.yml
	cd ansible && ansible-playbook site.yml --check --diff

deploy:         ## Apply the docker stack (honors enable_homekit)
	cd ansible && ansible-playbook site.yml --tags docker

up:             ## Start the default stack (frigate + caddy)
	cd docker && docker compose up -d

homekit:        ## Start incl. Scrypted (HomeKit/HKSV)
	cd docker && docker compose --profile homekit up -d

tunnel:         ## Start incl. Cloudflare Tunnel (HA via Zero Trust)
	cd docker && docker compose --profile tunnel up -d

down:           ## Stop the stack
	cd docker && docker compose down
