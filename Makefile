CC = clang
CFLAGS = -fobjc-arc -Wall -Wextra -Wno-unused-parameter -Isrc
FRAMEWORKS = -framework Foundation -framework IOKit -framework CoreFoundation -framework DiskArbitration
XCTEST_FLAGS = -framework XCTest \
  -F$(shell xcode-select -p)/Platforms/MacOSX.platform/Developer/Library/Frameworks \
  -rpath $(shell xcode-select -p)/Platforms/MacOSX.platform/Developer/Library/Frameworks

TARGET = wd_smart
LIB_SRCS = src/WDScsi.m src/WDDevice.m src/WDCommands.m src/WDEncryption.m src/WDArgs.m
SRCS = $(LIB_SRCS) src/main.m
OBJS = $(SRCS:.m=.o)

all: $(TARGET)

%.o: %.m src/WDSmart.h
	$(CC) $(CFLAGS) -c -o $@ $<

$(TARGET): $(OBJS)
	$(CC) $(FRAMEWORKS) -o $@ $(OBJS)

# Tests compile the library sources directly with -DTESTING so destructive
# paths (diskutil eraseDisk, zero-fill, countdown sleeps) are compiled out.
# Never link production .o files into the test binary.
wd_smart_tests: $(LIB_SRCS) wd_smart_tests.m src/WDSmart.h
	$(CC) $(CFLAGS) -DTESTING=1 $(FRAMEWORKS) $(XCTEST_FLAGS) -o $@ $(LIB_SRCS) wd_smart_tests.m

test: wd_smart_tests
	./wd_smart_tests

# Same tests under AddressSanitizer + UBSan so over-reads in buffer parsers
# actually fault instead of silently reading adjacent stack.
test-asan: $(LIB_SRCS) wd_smart_tests.m src/WDSmart.h
	$(CC) $(CFLAGS) -DTESTING=1 -fsanitize=address,undefined -fno-omit-frame-pointer -g \
		$(FRAMEWORKS) $(XCTEST_FLAGS) -o wd_smart_tests_asan $(LIB_SRCS) wd_smart_tests.m
	./wd_smart_tests_asan
	@rm -f wd_smart_tests_asan

coverage: $(LIB_SRCS) wd_smart_tests.m src/WDSmart.h
	$(CC) $(CFLAGS) -DTESTING=1 $(FRAMEWORKS) $(XCTEST_FLAGS) -fprofile-instr-generate -fcoverage-mapping \
		-o wd_smart_tests_cov $(LIB_SRCS) wd_smart_tests.m
	LLVM_PROFILE_FILE=wd_smart.profraw ./wd_smart_tests_cov >/dev/null 2>&1
	xcrun llvm-profdata merge -sparse wd_smart.profraw -o wd_smart.profdata
	xcrun llvm-cov report ./wd_smart_tests_cov -instr-profile=wd_smart.profdata $(LIB_SRCS)
	@rm -f wd_smart_tests_cov wd_smart.profraw wd_smart.profdata

clean:
	rm -rf $(TARGET) $(OBJS) wd_smart_tests wd_smart_tests_cov wd_smart_tests_asan *.dSYM wd_smart.profraw wd_smart.profdata

install: $(TARGET)
	cp $(TARGET) /usr/local/bin/

.PHONY: all clean install test test-asan coverage
