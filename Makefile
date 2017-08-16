SHELL=/bin/bash
ELASTIC_REGISTRY=docker.elastic.co

export PATH := ./bin:./venv/bin:$(PATH)

# Determine the version to build. Override by setting ELASTIC_VERSION env var.
ELASTIC_VERSION := $(shell ./bin/elastic-version)

ifdef STAGING_BUILD_NUM
  VERSION_TAG=$(ELASTIC_VERSION)-$(STAGING_BUILD_NUM)
else
  VERSION_TAG=$(ELASTIC_VERSION)
endif

# Build different images tagged as :version-<flavor>
# FIXME: basic license not available as of 6.0.0-beta1
# IMAGE_FLAVORS ?= oss basic platinum
IMAGE_FLAVORS ?= oss x-pack

# Which image flavor will additionally receive the plain `:version` tag
DEFAULT_IMAGE_FLAVOR ?= x-pack

VERSIONED_IMAGE := $(ELASTIC_REGISTRY)/logstash/logstash:$(VERSION_TAG)

FIGLET := pyfiglet -w 160 -f puffy

all: build test

test: lint docker-compose
	$(foreach FLAVOR, $(IMAGE_FLAVORS), \
	  $(FIGLET) "test: $(ELASTIC_VERSION)-$(FLAVOR)"; \
	  ./bin/pytest tests --image-flavor=$(FLAVOR); \
	)

lint: venv
	flake8 tests

build: dockerfile docker-compose env2yaml
	docker pull centos:7
	$(foreach FLAVOR, $(IMAGE_FLAVORS), \
	  docker build -t $(VERSIONED_IMAGE)-$(FLAVOR) \
	  -f build/logstash/Dockerfile-$(FLAVOR) build/logstash; \
	)

demo: docker-compose clean-demo
	docker-compose up

# Push the image to the dedicated push endpoint at "push.docker.elastic.co"
push: test
	docker tag $(VERSIONED_IMAGE) push.$(VERSIONED_IMAGE)
	docker push push.$(VERSIONED_IMAGE)
	docker rmi push.$(VERSIONED_IMAGE)

# The tests are written in Python. Make a virtualenv to handle the dependencies.
venv: requirements.txt
	test -d venv || virtualenv --python=python3.5 venv
	pip install -r requirements.txt
	touch venv

# Make a Golang container that can compile our env2yaml tool.
golang:
	docker build -t golang:env2yaml build/golang

# Compile "env2yaml", the helper for configuring logstash.yml via environment
# variables.
env2yaml: golang
	docker run --rm -i \
	  -v ${PWD}/build/logstash/env2yaml:/usr/local/src/env2yaml \
	  golang:env2yaml

# Generate the Dockerfiles from Jinja2 templates.
dockerfile: venv templates/Dockerfile.j2
	$(foreach FLAVOR, $(IMAGE_FLAVORS), \
	  jinja2 \
	    -D elastic_version='$(ELASTIC_VERSION)' \
	    -D staging_build_num='$(STAGING_BUILD_NUM)' \
	    -D image_flavor='$(FLAVOR)' \
	    templates/Dockerfile.j2 > build/logstash/Dockerfile-$(FLAVOR); \
	)


# Generate docker-compose files from Jinja2 templates.
docker-compose: venv
	$(foreach FLAVOR, $(IMAGE_FLAVORS), \
	  jinja2 \
	    -D version_tag='$(VERSION_TAG)' \
	    -D image_flavor='$(FLAVOR)' \
	    templates/docker-compose.yml.j2 > docker-compose-$(FLAVOR).yml; \
	)
	ln -sf docker-compose-$(DEFAULT_IMAGE_FLAVOR).yml docker-compose.yml

clean: clean-demo
	rm -f build/logstash/env2yaml/env2yaml build/logstash/Dockerfile
	rm -rf venv

clean-demo:
	docker-compose down
	docker-compose rm --force

.PHONY: build clean clean-demo demo push test
