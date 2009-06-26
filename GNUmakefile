# use GNU Make to run tests in parallel, and without depending on Rubygems
all:: test

T := $(wildcard test/test*.rb)
TO := $(subst .rb,.log,$(T))

test: $(T)
	@cat $(TO) | ruby test/aggregate.rb
	@$(RM) $(TO)
clean:
	$(RM) $(TO) $(addsuffix +,$(TO))


ifndef V
  quiet_pre = @echo '* $@';
  quiet_post = >$(t) 2>&1
else
  # we can't rely on -o pipefail outside of bash 3+,
  # so we use a stamp file to indicate success and
  # have rm fail if the stamp didn't get created
  stamp = $@$(log_suffix).ok
  quiet_pre = @echo $(ruby) $@ $(TEST_OPTS); ! test -f $(stamp) && (
  quiet_post = && > $(stamp) )>&2 | tee $(t); rm $(stamp) 2>/dev/null
endif
ruby = ruby
run_test = $(quiet_pre) setsid $(ruby) -w $@ $(TEST_OPTS) $(quiet_post) || \
  (sed "s,^,$(extra): ," >&2 < $(t); exit 1)

$(T): t = $(subst .rb,.log,$@)
$(T): export RUBYLIB := $(CURDIR)/lib:$(RUBYLIB)
$(T):
	$(run_test)

# using make instead of rake since Rakefile takes too long to load
manifest: Manifest.txt
Manifest.txt:
	git ls-files > $@+
	cmp $@+ $@ || mv $@+ $@
	$(RM) -f $@+

package: manifest
	git diff --exit-code HEAD^0
	$(RM) -r pkg/
	rake fix_perms
	rake package

libs := $(wildcard lib/*.rb lib/*/*.rb)
flay_flags =
flog_flags =
flay: $(libs)
	flay $(flay_flags) $^
flog: $(libs)
	flog $(flog_flags) $^
.PHONY: $(T) Manifest.txt
