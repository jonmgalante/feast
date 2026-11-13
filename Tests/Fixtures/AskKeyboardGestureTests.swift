import XCTest

final class KeyboardGestureTests: XCTestCase {
    @MainActor private func open(_ arguments:[String] = []) -> (XCUIApplication,XCUIElement) {
        let app=XCUIApplication();app.launchArguments=arguments;app.launch()
        let input=app.descendants(matching:.any).matching(identifier:"qa.composer").firstMatch
        XCTAssertTrue(input.waitForExistence(timeout:12));XCTAssertEqual(input.label,"Message Ask Feast");let initialHeight=input.frame.height;input.tap()
        XCTAssertTrue(app.keyboards.firstMatch.waitForExistence(timeout:5),"Software keyboard must be visible")
        XCTAssertEqual(input.frame.height,initialHeight,accuracy:1,"Keyboard must not compress the editor height")
        return (app,input)
    }
    @MainActor private func drag(_ input:XCUIElement,dx:CGFloat=0,dy:CGFloat=100,hold:TimeInterval=0.01) {
        let from=input.coordinate(withNormalizedOffset:CGVector(dx:0.4,dy:0.5))
        from.press(forDuration:hold,thenDragTo:from.withOffset(CGVector(dx:dx,dy:dy)),withVelocity:.fast,thenHoldForDuration:0)
    }
    @MainActor private func dismissInput(_ app:XCUIApplication,input:XCUIElement,velocity:XCUIGestureVelocity = .fast) {
        let from=input.coordinate(withNormalizedOffset:CGVector(dx:0.8,dy:0.5))
        let to=app.coordinate(withNormalizedOffset:CGVector(dx:0.8,dy:0.97))
        from.press(forDuration:0.01,thenDragTo:to,withVelocity:velocity,thenHoldForDuration:0)
    }
    @MainActor private func dragTranscriptDown(_ app:XCUIApplication, input:XCUIElement) {
        let transcript=app.scrollViews.matching(identifier:"qa.transcript").firstMatch
        XCTAssertTrue(transcript.exists)
        let frame=transcript.frame
        let navigation=app.navigationBars.firstMatch
        let top=max(frame.minY,navigation.exists ? navigation.frame.maxY : app.frame.minY)+16
        let bottom=min(frame.maxY,input.frame.minY)-24
        guard bottom-top>60 else { XCTFail("Transcript must have a usable visible viewport"); return }
        // Native interactive dismissal follows the finger toward the keyboard.
        // Start in unobscured transcript and drag through the keyboard area.
        let origin=app.coordinate(withNormalizedOffset:.zero)
        let from=origin.withOffset(CGVector(dx:frame.midX-app.frame.minX,dy:top+(bottom-top)*0.2-app.frame.minY))
        let to=origin.withOffset(CGVector(dx:frame.midX-app.frame.minX,dy:app.frame.height-25))
        from.press(forDuration:0.01,thenDragTo:to,withVelocity:.slow,thenHoldForDuration:0)
    }
    @MainActor private func hidden(_ app:XCUIApplication) {
        expectation(for:NSPredicate(format:"exists == false"),evaluatedWith:app.keyboards.firstMatch);waitForExpectations(timeout:4)
    }
    @MainActor private func screenshot(_ app:XCUIApplication) {
        let shot=XCTAttachment(screenshot:app.screenshot());shot.lifetime = .keepAlways;add(shot)
    }

    @MainActor private func expectComposerOverflow(_ expected:Bool, in app:XCUIApplication) {
        let metrics=app.staticTexts["qa.editorMetrics"]
        XCTAssertTrue(metrics.waitForExistence(timeout:3))
        let prefix="overflow=\(expected) scrolling=true indicator=true "
        expectation(for:NSPredicate(format:"label BEGINSWITH %@",prefix),evaluatedWith:metrics)
        waitForExpectations(timeout:4)
    }

    @MainActor func testEmptyComposerFitsAcrossOrdinaryDynamicTypeSizes() {
        for size in ["xSmall","small","medium","large","xLarge","xxLarge","xxxLarge"] {
            let (app,input)=open(["-emptyDraft","-size="+size])
            expectComposerOverflow(false,in:app)
            input.swipeUp(velocity:.slow);expectComposerOverflow(false,in:app)
            screenshot(app);dismissInput(app,input:input,velocity:.slow);hidden(app)
            XCTAssertEqual(input.value as? String,"")
            app.terminate()
        }
    }
    @MainActor func testComposerScrollsOnlyBeyondFiveLines() {
        for size in ["small","large","xxxLarge"] {
            for lines in [1,5,6] {
                let (app,input)=open(["-draftLines=\(lines)","-size="+size])
                expectComposerOverflow(lines>5,in:app)
                input.swipeUp(velocity:.slow);expectComposerOverflow(lines>5,in:app)
                XCTAssertEqual(input.value as? String,(1...lines).map {"Line \($0)"}.joined(separator:"\n"))
                screenshot(app);app.terminate()
            }
        }
    }
    @MainActor func testDeletingOverflowingDraftRestoresFittingComposer() {
        let (app,input)=open(["-emptyDraft"])
        let five=(1...5).map {"Line \($0)"}.joined(separator:"\n")
        let sixth="\nLine 6"
        input.typeText(five+sixth);expectComposerOverflow(true,in:app)
        input.typeText(String(repeating:XCUIKeyboardKey.delete.rawValue,count:sixth.count))
        XCTAssertEqual(input.value as? String,five);expectComposerOverflow(false,in:app)
        input.typeText(String(repeating:XCUIKeyboardKey.delete.rawValue,count:five.count))
        XCTAssertEqual(input.value as? String,"");expectComposerOverflow(false,in:app)
        dismissInput(app,input:input,velocity:.slow);hidden(app);screenshot(app)
    }

    @MainActor func testShortInputSlowNativeDrag() {
        let (app,input)=open()
        dismissInput(app,input:input,velocity:.slow)
        hidden(app);XCTAssertEqual(input.value as? String,"Unsent synthetic draft");screenshot(app)
    }
    @MainActor func testEmptyDraftNativeDismissalAndPlaceholder() {
        let (app,input)=open(["-emptyDraft"])
        XCTAssertEqual(input.value as? String,"")
        XCTAssertGreaterThan(input.frame.height,25);XCTAssertLessThan(input.frame.height,50)
        screenshot(app);dismissInput(app,input:input);hidden(app)
        XCTAssertEqual(input.value as? String,"")
    }
    @MainActor func testComposerOneToFiveLineSizing() {
        var heights:[CGFloat]=[]
        for lines in [1,5,6] {
            let (app,input)=open(["-draftLines=\(lines)"])
            heights.append(input.frame.height)
            XCTAssertEqual(input.value as? String,(1...lines).map {"Line \($0)"}.joined(separator:"\n"))
            screenshot(app);app.terminate()
        }
        XCTAssertGreaterThan(heights[1],heights[0]+70)
        XCTAssertEqual(heights[1],heights[2],accuracy:1,"Composer stops growing after five lines")
        XCTAssertLessThan(heights[2],130)
    }
    @MainActor func testWrappedDraftNativeSizingAndScrolling() {
        let (app,input)=open(["-wrappedDraft"]);let draft=input.value as? String
        XCTAssertGreaterThan(input.frame.height,110);XCTAssertLessThan(input.frame.height,130)
        screenshot(app);input.swipeUp(velocity:.slow)
        XCTAssertTrue(app.keyboards.firstMatch.exists);XCTAssertEqual(input.value as? String,draft)
        dismissInput(app,input:input);hidden(app);XCTAssertEqual(input.value as? String,draft)
    }
    @MainActor func testTrailingNewlineGrowsComposerAndEditingWorks() {
        let (app,input)=open(["-emptyDraft"]);input.typeText("Line 1");let height=input.frame.height
        input.typeText("\n")
        XCTAssertEqual(input.value as? String,"Line 1\n")
        XCTAssertGreaterThan(input.frame.height,height+10)
        input.typeText("Second line")
        XCTAssertEqual(input.value as? String,"Line 1\nSecond line");screenshot(app)
    }

    @MainActor func testShortInputDownSwipe() {
        let (app,input)=open();dismissInput(app,input:input);hidden(app)
        XCTAssertEqual(input.value as? String,"Unsent synthetic draft");screenshot(app)
    }
    @MainActor func testShortInputUpAndHorizontalPreserveEditing() {
        let (app,input)=open();drag(input,dy:-70)
        XCTAssertTrue(app.keyboards.firstMatch.exists)
        drag(input,dx:70,dy:0);XCTAssertTrue(app.keyboards.firstMatch.exists)
        XCTAssertEqual(input.value as? String,"Unsent synthetic draft")
        input.typeText("!");XCTAssertTrue((input.value as? String ?? "").contains("!"));screenshot(app)
    }
    @MainActor func testLongPressCaretDragPreservesEditing() {
        let (app,input)=open();drag(input,dy:75,hold:0.8)
        XCTAssertTrue(app.keyboards.firstMatch.exists)
        XCTAssertEqual(input.value as? String,"Unsent synthetic draft");screenshot(app)
    }
    @MainActor func testSelectedTextDownDragPreservesEditing() {
        let (app,input)=open();input.doubleTap();screenshot(app)
        drag(input,dy:75)
        XCTAssertTrue(app.keyboards.firstMatch.exists)
        XCTAssertEqual(input.value as? String,"Unsent synthetic draft");screenshot(app)
    }
    @MainActor func testLongDraftScrollingPreservesEditing() {
        let (app,input)=open(["-longDraft"]);let draft=input.value as? String
        input.swipeUp(velocity:.slow);input.swipeUp(velocity:.slow)
        XCTAssertTrue(app.keyboards.firstMatch.exists)
        drag(input,dy:65)
        XCTAssertTrue(app.keyboards.firstMatch.exists,"Downward swipe inside a scrolled draft must scroll, not dismiss")
        XCTAssertEqual(input.value as? String,draft);screenshot(app)
    }
    @MainActor func testAccessibilityInputDownSwipe() {
        let (app,input)=open(["-accessibility"]);dismissInput(app,input:input);hidden(app)
        XCTAssertEqual(input.value as? String,"Unsent synthetic draft");screenshot(app)
    }
    @MainActor func testAccessibilityLongDraftScroll() {
        let (app,input)=open(["-accessibility","-longDraft"]);let draft=input.value as? String
        input.swipeUp(velocity:.slow);input.swipeUp(velocity:.slow)
        drag(input,dy:65);XCTAssertTrue(app.keyboards.firstMatch.exists)
        XCTAssertEqual(input.value as? String,draft);screenshot(app)
    }
    @MainActor func testTranscriptScrollDismissesAtBottom() {
        let (app,input)=open();let draft=input.value as? String
        let transcript=app.scrollViews.matching(identifier:"qa.transcript").firstMatch
        XCTAssertTrue(transcript.exists);dragTranscriptDown(app,input:input);hidden(app)
        XCTAssertEqual(input.value as? String,draft);screenshot(app)
    }
    @MainActor func testEmptyTranscriptDismisses() {
        let (app,input)=open(["-empty"]);let draft=input.value as? String
        let transcript=app.scrollViews.matching(identifier:"qa.transcript").firstMatch
        XCTAssertTrue(transcript.exists);dragTranscriptDown(app,input:input);hidden(app)
        XCTAssertEqual(input.value as? String,draft);screenshot(app)
    }
    @MainActor func testLongDraftNativeDismissalPreservesText() {
        let (app,input)=open(["-longDraft"]);let draft=input.value as? String
        input.swipeUp(velocity:.slow)
        dismissInput(app,input:input);hidden(app)
        XCTAssertEqual(input.value as? String,draft);screenshot(app)
    }
    @MainActor func testAccessibilityLongDraftNativeDismissalPreservesText() {
        let (app,input)=open(["-accessibility","-longDraft"]);let draft=input.value as? String
        input.swipeUp(velocity:.slow)
        dismissInput(app,input:input);hidden(app)
        XCTAssertEqual(input.value as? String,draft);screenshot(app)
    }
    @MainActor func testTranscriptDismissesAtMiddleAndTop() {
        let (app,input)=open();let draft=input.value as? String
        let transcript=app.scrollViews.matching(identifier:"qa.transcript").firstMatch
        dragTranscriptDown(app,input:input);hidden(app)
        input.tap();XCTAssertTrue(app.keyboards.firstMatch.waitForExistence(timeout:3))
        dragTranscriptDown(app,input:input);hidden(app)
        var attempts=0
        while !app.staticTexts["Synthetic question 0"].isHittable && attempts<24 {
            dragTranscriptDown(app,input:input);attempts+=1
        }
        XCTAssertTrue(app.staticTexts["Synthetic question 0"].isHittable,"Reached oldest question")
        input.tap();XCTAssertTrue(app.keyboards.firstMatch.waitForExistence(timeout:3))
        dragTranscriptDown(app,input:input);hidden(app)
        XCTAssertEqual(input.value as? String,draft);screenshot(app)
    }
    @MainActor func testTranscriptContextMenuStillWorks() {
        let (app,input)=open();let draft=input.value as? String
        let questions=app.staticTexts.matching(NSPredicate(format:"label BEGINSWITH %@","Synthetic question "))
        var visibleQuestion=questions.allElementsBoundByIndex.first { $0.isHittable }
        var attempts=0
        while visibleQuestion == nil && attempts<3 {
            dragTranscriptDown(app,input:input);attempts+=1
            visibleQuestion=questions.allElementsBoundByIndex.first { $0.isHittable }
        }
        guard let question=visibleQuestion else { XCTFail("A synthetic question must be visible for its context menu"); return }
        XCTAssertTrue(question.isHittable)
        question.press(forDuration:1)
        XCTAssertTrue(app.buttons["Copy question"].waitForExistence(timeout:3))
        app.buttons["Copy question"].tap()
        XCTAssertEqual(input.value as? String,draft);screenshot(app)
    }
    @MainActor func testDismissalDoesNotCancelAnswerOrSendDraft() {
        let (app,input)=open(["-slowAnswer"])
        app.buttons["Send message"].tap()
        XCTAssertTrue(app.buttons["Stop"].waitForExistence(timeout:3))
        input.tap();XCTAssertTrue(app.keyboards.firstMatch.waitForExistence(timeout:3))
        input.typeText("Next unsent draft")
        dismissInput(app,input:input);hidden(app)
        XCTAssertTrue(app.buttons["Stop"].exists,"Dismissal must not cancel the active request")
        XCTAssertEqual(input.value as? String,"Next unsent draft")
        XCTAssertTrue(app.staticTexts["Synthetic answer complete. The keyboard gesture did not send or cancel anything."].waitForExistence(timeout:25))
        XCTAssertEqual(input.value as? String,"Next unsent draft");screenshot(app)
    }

    @MainActor func testAccessibilityLongPressCaretAndSelection() {
        let (app,input)=open(["-accessibility"])
        drag(input,dy:75,hold:0.8);XCTAssertTrue(app.keyboards.firstMatch.exists)
        input.doubleTap();drag(input,dy:75);XCTAssertTrue(app.keyboards.firstMatch.exists)
        XCTAssertEqual(input.value as? String,"Unsent synthetic draft");screenshot(app)
    }
    @MainActor func testHistoryAndNewChatPreserveDraftsWithoutRestoringFocus() {
        let (app,input)=open();let draft=input.value as? String
        app.buttons["ask.history"].tap();hidden(app)
        app.buttons["Done"].tap();XCTAssertFalse(app.keyboards.firstMatch.exists)
        XCTAssertEqual(input.value as? String,draft)
        input.tap();XCTAssertTrue(app.keyboards.firstMatch.waitForExistence(timeout:3))
        app.buttons["ask.history"].tap();hidden(app)
        app.staticTexts["Other synthetic chat"].tap()
        XCTAssertEqual(input.value as? String,"Other preserved draft")
        XCTAssertFalse(app.keyboards.firstMatch.exists)
        input.tap();XCTAssertTrue(app.keyboards.firstMatch.waitForExistence(timeout:3))
        app.buttons["ask.newChat"].tap();hidden(app)
        XCTAssertTrue(["","Ask Feast…"].contains(input.value as? String ?? "<missing>"),"New chat has an empty draft")
        app.buttons["ask.history"].tap();app.staticTexts["Keyboard long chat"].tap()
        XCTAssertEqual(input.value as? String,draft)
        XCTAssertFalse(app.keyboards.firstMatch.exists);screenshot(app)
    }

}
