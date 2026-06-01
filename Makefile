CC = clang
CFLAGS = -fobjc-arc -framework Foundation -framework IOKit -framework CoreFoundation
XCTEST_FLAGS = -framework XCTest -F$(shell xcode-select -p)/Platforms/MacOSX.platform/Developer/Library/Frameworks -rpath $(shell xcode-select -p)/Platforms/MacOSX.platform/Developer/Library/Frameworks
TARGET = wd_smart

all: $(TARGET)

$(TARGET): wd_smart.m
	$(CC) $(CFLAGS) -o $@ $<

test: wd_smart_tests.m wd_smart.m
	$(CC) $(CFLAGS) $(XCTEST_FLAGS) -o wd_smart_tests $<
	./wd_smart_tests

coverage: wd_smart_tests.m wd_smart.m
	$(CC) $(CFLAGS) $(XCTEST_FLAGS) -fprofile-instr-generate -fcoverage-mapping -o wd_smart_tests_cov $<
	LLVM_PROFILE_FILE=wd_smart.profraw ./wd_smart_tests_cov >/dev/null 2>&1
	xcrun llvm-profdata merge -sparse wd_smart.profraw -o wd_smart.profdata
	xcrun llvm-cov report ./wd_smart_tests_cov -instr-profile=wd_smart.profdata wd_smart.m
	@rm -f wd_smart_tests_cov wd_smart.profraw wd_smart.profdata

clean:
	rm -f $(TARGET) wd_smart_tests wd_smart_tests_cov wd_smart.profraw wd_smart.profdata

install: $(TARGET)
	cp $(TARGET) /usr/local/bin/

.PHONY: all clean install test coverage
