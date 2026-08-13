.PHONY: help lint validate deps hooks check-config check deploy health preflight

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

preflight:      ## Full local rehearsal (lint + ansible syntax-check)
	./scripts/preflight.sh

check-config:   ## Pre-deploy gate: required files/keys present, no placeholders, cross-file consistency
	./scripts/check-config.sh

validate: lint  ## All static checks (the camera stack is podman-Quadlet now — units validate at deploy)

check:          ## Ansible dry-run against inventory.yml
	cd ansible && ansible-playbook site.yml --check --diff

deploy: check-config   ## Apply the stack (refuses to run until config is complete)
	cd ansible && ansible-playbook site.yml

health:         ## SSH health sweep (mem/disk/SMART/temp/units). HOST=ip to override
	./scripts/health.sh
