.PHONY: verify goldens

verify: ## Render the fixture cluster, compare the goldens and diff the bootstrap against the pinned cluster-aws.
	hack/verify.sh

goldens: ## Rewrite the render goldens under hack/fixture/goldens.
	hack/verify.sh update
