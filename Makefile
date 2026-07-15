EMACS ?= emacs

# A space-separated list of required package names
DEPS = gptel

INIT_PACKAGES="(progn \
  (require 'package) \
  (push '(\"melpa\" . \"https://melpa.org/packages/\") package-archives) \
  (package-initialize) \
  (dolist (pkg '(PACKAGES)) \
    (unless (package-installed-p pkg) \
      (unless (assoc pkg package-archive-contents) \
	(package-refresh-contents)) \
      (package-install pkg))) \
  )"

all: compile package-lint test clean-elc

package-lint:
	${EMACS} -Q --eval $(subst PACKAGES,package-lint,${INIT_PACKAGES}) -batch -f package-lint-batch-and-exit gptel-cpp-complete.el gptel-cpp-complete-test.el

compile: clean-elc
	${EMACS} -Q --eval $(subst PACKAGES,${DEPS},${INIT_PACKAGES}) -L . -batch -f batch-byte-compile gptel-cpp-complete.el gptel-cpp-complete-test.el

test: clean-elc
	${EMACS} -Q --eval $(subst PACKAGES,${DEPS},${INIT_PACKAGES}) -L . -batch -l gptel-cpp-complete-test --eval '(ert-run-tests-batch "^gptel-cpp-complete-test")'

clean-elc:
	rm -f *.elc

.PHONY:	all compile test clean-elc package-lint
