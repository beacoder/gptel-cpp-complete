EMACS ?= emacs

.PHONY: test clean

test:
	$(EMACS) --batch -L . \
	  --eval "(require 'package)" \
	  --eval "(package-initialize)" \
	  -l gptel-cpp-complete.el \
	  -l gptel-cpp-complete-test.el \
	  -f gptel-cpp-complete-run-tests

clean:
	rm -f *.elc
