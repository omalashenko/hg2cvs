HG2CVS_ROOT= $(shell pwd)
HG_REPO    = $(HG2CVS_ROOT)/hgrepo
CVS_REPO   = $(HG2CVS_ROOT)/cvsrepo
CVSROOT    = $(HG2CVS_ROOT)/cvsrepo/cvsroot

export CVSROOT

all: run

prepare $(HG_REPO)/source $(HG_REPO)/gate: hgrepo.tar.bz2
	mkdir $(HG_REPO) $(CVS_REPO)
	tar xf hgrepo.tar.bz2 -C $(HG_REPO)
	touch $(HG_REPO)/*
	hg clone -rnull $(HG_REPO)/source $(HG_REPO)/gate
	echo "[hooks]"                                             > $(HG_REPO)/gate/.hg/hgrc
	echo "changegroup = $(HG2CVS_ROOT)/hg2cvs.sh $(CVS_REPO)" >> $(HG_REPO)/gate/.hg/hgrc

.PHONY: purge
purge:
	rm -rf $(HG_REPO) $(CVS_REPO)

.PHONY: clean
clean $(CVS_REPO)/default $(CVS_REPO)/cvsroot: $(HG_REPO)/gate
	rm -rf $(CVS_REPO)/* $(HG_REPO)/gate/.hg/hg2cvs*
	hg -R $(HG_REPO)/gate strip --no-backup 0
	hg clone $(HG_REPO)/gate $(CVS_REPO)/default
	cvs -d $(CVS_REPO)/cvsroot init
	cvs -d $(CVS_REPO)/cvsroot checkout -d $(CVS_REPO)/default .

.PHONY: run
run: clean
	hg -R $(HG_REPO)/source push $(HG_REPO)/gate

