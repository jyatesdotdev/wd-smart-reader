CC = clang
CFLAGS = -fobjc-arc -Wall -Isrc
FRAMEWORKS = -framework Foundation -framework IOKit -framework CoreFoundation
XCTEST_FLAGS = -framework XCTest \
  -F$(shell xcode-select -p)/Platforms/MacOSX.platform/Developer/Library/Frameworks \
  -rpath $(shell xcode-select -p)/Platforms/MacOSX.platform/Developer/Library/Frameworks

TARGET = wd_smart
SRCS = src/WDScsi.m src/WDDevice.m src/WDCommands.m src/WDEncryption.m src/main.m
OBJS = $(SRCS:.m=.o)
LIB_SRCS = src/WDScsi.m src/WDDevice.m src/WDCommands.m src/WDEncryption.m
LIB_OBJS = $(LIB_SRCS:.m=.o)

all: $(TARGET)

%.o: %.m src/WDSmart.h
	$(CC) $(CFLAGS) -c -o $@ $<

$(TARGET): $(OBJS)
	$(CC) $(FRAMEWORKS) -o $@ $(OBJS)

test: $(LIB_OBJS) wd_smart_tests.m src/WDSmart.h
	$(CC) $(CFLAGS) $(FRAMEWORKS) $(XCTEST_FLAGS) -o wd_smart_tests $(LIB_OBJS) wd_smart_tests.m
	./wd_smart_tests

coverage: $(LIB_SRCS) wd_smart_tests.m src/WDSmart.h
	$(CC) $(CFLAGS) $(FRAMEWORKS) $(XCTEST_FLAGS) -fprofile-instr-generate -fcoverage-mapping \
		-o wd_smart_tests_cov $(LIB_SRCS) wd_smart_tests.m
	LLVM_PROFILE_FILE=wd_smart.profraw ./wd_smart_tests_cov >/dev/null 2>&1
	xcrun llvm-profdata merge -sparse wd_smart.profraw -o wd_smart.profdata
	xcrun llvm-cov report ./wd_smart_tests_cov -instr-profile=wd_smart.profdata $(LIB_SRCS)
	@rm -f wd_smart_tests_cov wd_smart.profraw wd_smart.profdata

clean:
	rm -f $(TARGET) $(OBJS) wd_smart_tests wd_smart_tests_cov wd_smart.profraw wd_smart.profdata

install: $(TARGET)
	cp $(TARGET) /usr/local/bin/

.PHONY: all clean install test coverage
