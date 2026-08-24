// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {ClaimsHarness} from "./ClaimsHarness.sol";

contract ClaimsExtractJsonObjectTest is Test {
    ClaimsHarness internal harness;
    string internal constant TARGET = '"extractedParameters":';

    function setUp() public {
        harness = new ClaimsHarness();
    }

    function test_extractsRealExtractedParameters() public view {
        string memory ctx =
            '{"contextAddress":"0xabc","extractedParameters":{"username":"a40m4DoQI1k"},"providerHash":"0xdef"}';

        bytes memory got = harness.extractJsonObjectFromContext(ctx, TARGET);
        assertEq(string(got), '{"username":"a40m4DoQI1k"}');
    }

    function test_returnsEmptyWhenTargetMissing() public view {
        string memory ctx = '{"contextAddress":"0xabc","providerHash":"0xdef"}';
        bytes memory got = harness.extractJsonObjectFromContext(ctx, TARGET);
        assertEq(got.length, 0);
    }

    function test_handlesNestedObjects() public view {
        string memory ctx = '{"extractedParameters":{"meta":{"sub":"x"},"u":"a"},"providerHash":"0x"}';
        bytes memory got = harness.extractJsonObjectFromContext(ctx, TARGET);
        assertEq(string(got), '{"meta":{"sub":"x"},"u":"a"}');
    }

    function test_handlesClosingBraceInsideStringValue() public view {
        string memory ctx = '{"extractedParameters":{"u":"a}b{c","other":"v"},"providerHash":"0x"}';
        bytes memory got = harness.extractJsonObjectFromContext(ctx, TARGET);
        assertEq(string(got), '{"u":"a}b{c","other":"v"}');
    }

    function test_handlesEscapedQuoteInsideValue() public view {
        // The JSON value is a"b — i.e. one backslash escaping one quote.
        string memory ctx = '{"extractedParameters":{"u":"a\\"b","other":"v"},"providerHash":"0x"}';
        bytes memory got = harness.extractJsonObjectFromContext(ctx, TARGET);
        assertEq(string(got), '{"u":"a\\"b","other":"v"}');
    }

    function test_returnsEmptyWhenObjectNeverCloses() public view {
        string memory ctx = '{"extractedParameters":{"u":"a"';
        bytes memory got = harness.extractJsonObjectFromContext(ctx, TARGET);
        assertEq(got.length, 0);
    }

    function test_skipsWhitespaceBeforeOpenBrace() public view {
        string memory ctx = '{"extractedParameters":  {"u":"a"}}';
        bytes memory got = harness.extractJsonObjectFromContext(ctx, TARGET);
        assertEq(string(got), '{"u":"a"}');
    }

    function test_returnsEmptyWhenNextNonSpaceIsNotOpenBrace() public view {
        string memory ctx = '{"extractedParameters":"oops"}';
        bytes memory got = harness.extractJsonObjectFromContext(ctx, TARGET);
        assertEq(got.length, 0);
    }
}
