.PHONY: help lint validate compose-config up homekit down deps check

help:           ## Show this help
	@grep -E '^[a-z-]+:.*?## ' $(MAKEFILE_LIST) | awk -F':.*?## ' '{printf "  %-14s %s\n", $$1, $$2}'

deps:           ## Install ansible collections
	cd ansible && ansible-galaxy collection install -r requirements.yml

lint:           ## yamllint + ansible-lint
	yamllint .
	cd ansible && ansible-lint

compose-config: ## Validate docker compose (needs docker/.env)
	cd docker && docker compose config -q && echo "compose OK"
	cd docker && docker compose --profile homekit config -q && echo "compose (homekit) OK"

validate: lint compose-config  ## All static checks

check:          ## Ansible dry-run against inventory.yml
	cd ansible && ansible-playbook site.yml --check --diff

up:             ## Start the default stack (frigate + caddy)
	cd docker && docker compose up -d

homekit:        ## Start incl. Scrypted (HomeKit/HKSV)
	cd docker && docker compose --profile homekit up -d

down:           ## Stop the stack
	cd docker && docker compose down
