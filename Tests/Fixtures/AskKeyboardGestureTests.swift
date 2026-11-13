import XCTest

final class KeyboardGestureTests: XCTestCase {
    @MainActor private func open(_ arguments:[String] = []) -> (XCUIApplication,XCUIElement) {
        let app=XCUIApplication();app.launchArguments=arguments;app.launch()
        let input=app.descendants(matching:.any).matching(identifier:"qa.composer").firstMatch
        XCTAssertTrue(input.waitForExistence(timeout:12));XCTAssertEqual(input.label,"Message Ask Feast");let initialHeight=input.frame.height;input.tap()
        XCTAssertTrue(app.keyboards.firstMatch.waitForExistence(timeout:5),"Software keyboard must be visible")
        if input.elementType == .textView {
            XCTAssertEqual(input.frame.height,initialHeight,accuracy:1,"The accessibility editor keeps its fixed height")
        } else {
            // Build27's native 1...5-line TextField may choose fewer visible lines
            // when the keyboard reduces available space. It must remain usable.
            XCTAssertGreaterThan(input.frame.height,0);XCTAssertTrue(input.isHittable)
        }
        return (app,input)
    }
    @MainActor private func drag(_ input:XCUIElement,dx:CGFloat=0,dy:CGFloat=100,hold:TimeInterval=0.01,velocity:XCUIGestureVelocity = .fast) {
        let from=input.coordinate(withNormalizedOffset:CGVector(dx:0.4,dy:0.5))
        from.press(forDuration:hold,thenDragTo:from.withOffset(CGVector(dx:dx,dy:dy)),withVelocity:velocity,thenHoldForDuration:0)
    }
    @MainActor private func dismissViaHistory(_ app:XCUIApplication) {
        app.buttons["ask.history"].tap();hidden(app);app.buttons["Done"].tap()
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
        let prefix="overflow=\(expected) "
        expectation(for:NSPredicate(format:"label BEGINSWITH %@",prefix),evaluatedWith:metrics)
        waitForExpectations(timeout:4)
    }

    @MainActor private func expectNativeFieldConfiguration(in app:XCUIApplication) {
        let metrics=app.staticTexts["qa.editorMetrics"]
        XCTAssertTrue(metrics.waitForExistence(timeout:3))
        // Native TextField controls its own content metrics/leading. Do not impose
        // the removed custom TextEditor's pixel-for-pixel sizing contract.
        expectation(for:NSPredicate(format:"label CONTAINS %@ AND label CONTAINS %@","indicator=false","alwaysBounce=false"),evaluatedWith:metrics)
        waitForExpectations(timeout:4)
    }

    @MainActor func testEmptyNativeComposerAcrossOrdinaryDynamicTypeSizes() {
        for size in ["xSmall","small","medium","large","xLarge","xxLarge","xxxLarge"] {
            let (app,input)=open(["-emptyDraft","-size="+size])
            expectNativeFieldConfiguration(in:app)
            input.swipeUp(velocity:.slow);expectNativeFieldConfiguration(in:app)
            screenshot(app);dismissViaHistory(app);hidden(app)
            XCTAssertTrue(["","Ask Feast…"].contains(input.value as? String ?? "<missing>"),"Native empty field must show its placeholder, not a draft")
            app.terminate()
        }
    }
    @MainActor func testNativeComposerGrowthCapAcrossTypeSizes() {
        for size in ["small","large","xxxLarge"] {
            var heights:[CGFloat]=[]
            for lines in [1,5,6] {
                let (app,input)=open(["-draftLines=\(lines)","-size="+size])
                heights.append(input.frame.height)
                expectNativeFieldConfiguration(in:app)
                if lines>5 {expectComposerOverflow(true,in:app)}
                input.swipeUp(velocity:.slow)
                XCTAssertEqual(input.value as? String,(1...lines).map {"Line \($0)"}.joined(separator:"\n"))
                screenshot(app);app.terminate()
            }
            XCTAssertGreaterThan(heights[1],heights[0]+40)
            XCTAssertEqual(heights[1],heights[2],accuracy:1,"Native field stops growing at five lines")
        }
    }
    @MainActor func testDeletingOverflowingDraftRestoresFittingComposer() {
        let (app,input)=open(["-emptyDraft"])
        let five=(1...5).map {"Line \($0)"}.joined(separator:"\n")
        let sixth="\nLine 6"
        input.typeText(five+sixth);expectComposerOverflow(true,in:app)
        input.typeText(String(repeating:XCUIKeyboardKey.delete.rawValue,count:sixth.count))
        XCTAssertEqual(input.value as? String,five);expectNativeFieldConfiguration(in:app)
        input.typeText(String(repeating:XCUIKeyboardKey.delete.rawValue,count:five.count))
        let emptyValue=input.value as? String
        XCTAssertTrue(["","Ask Feast…"].contains(emptyValue ?? "<missing>"),"Native empty field must show its placeholder, not a draft; actual value: \(String(reflecting:emptyValue))");expectNativeFieldConfiguration(in:app)
        dismissViaHistory(app);hidden(app);screenshot(app)
    }

    @MainActor func testShortInputDownDragDoesNotRubberBand() {
        let (app,input)=open()
        drag(input,dy:110)
        XCTAssertEqual(input.value as? String,"Unsent synthetic draft")
        let metrics=app.staticTexts["qa.editorMetrics"].label
        XCTAssertTrue(metrics.contains("minFit=0.0 maxFit=0.0"),"Fitting input should not rubber-band: \(metrics)")
        screenshot(app);dismissViaHistory(app);hidden(app)
    }
    @MainActor func testEmptyDraftUsesOriginalNativeField() {
        let (app,input)=open(["-emptyDraft"])
        XCTAssertTrue(["","Ask Feast…"].contains(input.value as? String ?? "<missing>"),"Native empty field must show its placeholder, not a draft")
        XCTAssertGreaterThan(input.frame.height,15);XCTAssertLessThan(input.frame.height,50)
        screenshot(app);dismissViaHistory(app);hidden(app)
        XCTAssertTrue(["","Ask Feast…"].contains(input.value as? String ?? "<missing>"),"Native empty field must show its placeholder, not a draft")
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
    @MainActor func testWrappedDraftNativeFieldSizingAndScrolling() {
        let (app,input)=open(["-wrappedDraft"]);let draft=input.value as? String
        XCTAssertGreaterThan(input.frame.height,90);XCTAssertLessThan(input.frame.height,130)
        screenshot(app);input.swipeUp(velocity:.slow)
        XCTAssertTrue(app.keyboards.firstMatch.exists);XCTAssertEqual(input.value as? String,draft)
        dismissViaHistory(app);hidden(app);XCTAssertEqual(input.value as? String,draft)
    }
    @MainActor func testTrailingNewlineGrowsComposerAndEditingWorks() {
        let (app,input)=open(["-emptyDraft"]);input.typeText("Line 1");let height=input.frame.height
        input.typeText("\n")
        XCTAssertEqual(input.value as? String,"Line 1\n")
        XCTAssertGreaterThan(input.frame.height,height+10)
        input.typeText("Second line")
        XCTAssertEqual(input.value as? String,"Line 1\nSecond line");screenshot(app)
    }

    @MainActor func testComposerDownSwipeDismissesAndCanRefocus() {
        let (app,input)=open();let draft=input.value as? String
        // A short, slow drag should work without reaching the keyboard or flicking.
        for (dx,dy,velocity):(CGFloat,CGFloat,XCUIGestureVelocity) in [
            (0,42,.slow),(24,55,.fast),(-24,55,.slow),(0,60,XCUIGestureVelocity(rawValue:40))
        ] {
            drag(input,dx:dx,dy:dy,velocity:velocity);hidden(app)
            XCTAssertEqual(input.value as? String,draft);latestTailVisible(app)
            input.tap();XCTAssertTrue(app.keyboards.firstMatch.waitForExistence(timeout:3))
        }
        input.typeText("!");XCTAssertTrue((input.value as? String ?? "").contains("!"));screenshot(app)
    }
    @MainActor func testEmptyComposerDownSwipeDismisses() {
        let (app,input)=open(["-emptyDraft"])
        drag(input,dy:42,velocity:.slow);hidden(app)
        XCTAssertTrue(["","Ask Feast…"].contains(input.value as? String ?? "<missing>"));screenshot(app)
    }
    @MainActor func testMultilineComposerDownSwipeDismisses() {
        let (app,input)=open(["-draftLines=5"]);let draft=input.value as? String
        drag(input,dy:42,velocity:.slow);hidden(app)
        XCTAssertEqual(input.value as? String,draft);screenshot(app)
    }
    @MainActor func testAccessibilityComposerDownSwipeDismisses() {
        let (app,input)=open(["-accessibility"]);let draft=input.value as? String
        drag(input,dy:42,velocity:.slow);hidden(app)
        XCTAssertEqual(input.value as? String,draft);screenshot(app)
    }
    @MainActor func testBlankComposerSpaceDismissesIncludingScrolledDraft() {
        for arguments in [[], ["-longDraft"]] {
            let (app,input)=open(arguments);let draft=input.value as? String
            if !arguments.isEmpty {input.swipeUp(velocity:.slow)}
            // Inner card padding, outer padding, and blank space between controls.
            for region in 0..<3 {
                let frame=input.frame
                let send=app.buttons["Send message"].frame
                let point=region == 0 ? CGPoint(x:frame.minX-6,y:frame.midY) :
                    region == 1 ? CGPoint(x:frame.minX-20,y:frame.midY) :
                    CGPoint(x:frame.midX,y:send.midY)
                let from=app.coordinate(withNormalizedOffset:.zero).withOffset(CGVector(dx:point.x-app.frame.minX,dy:point.y-app.frame.minY))
                from.press(forDuration:region == 1 ? 0.8 : 0.01,thenDragTo:from.withOffset(CGVector(dx:8,dy:42)),withVelocity:.slow,thenHoldForDuration:0)
                hidden(app);XCTAssertEqual(input.value as? String,draft)
                XCTAssertTrue(app.buttons["Send message"].exists,"Blank-space dismissal must not send the draft")
                input.tap();XCTAssertTrue(app.keyboards.firstMatch.waitForExistence(timeout:3))
            }
            screenshot(app);app.terminate()
        }
    }

    @MainActor func testLongDraftScrollReachesTopBeforeNextSwipeDismisses() {
        let (app,input)=open(["-draftLines=8"]);let draft=input.value as? String
        input.swipeUp(velocity:.slow)
        let metrics=app.staticTexts["qa.editorMetrics"]
        XCTAssertTrue(metrics.label.contains("atTop=false"),"Start below the beginning of an overflowing draft")
        for _ in 0..<6 {
            if metrics.label.contains("atTop=true") {break}
            drag(input,dy:80,velocity:.slow)
            XCTAssertTrue(app.keyboards.firstMatch.exists,"A scroll that starts below top may not become a dismissal")
        }
        XCTAssertTrue(metrics.label.contains("atTop=true"),"Native scrolling reached the beginning")
        drag(input,dy:42,velocity:.slow);hidden(app)
        XCTAssertEqual(input.value as? String,draft);screenshot(app)
    }
    @MainActor func testComposerAttachmentControlsStayIndependent() {
        let (app,input)=open(["-photos","-attachment"]);let draft=input.value as? String
        let photo=app.buttons["Attach one screenshot"]
        let remove=app.buttons["Remove selected screenshot"]
        XCTAssertTrue(photo.exists);XCTAssertTrue(remove.exists)
        drag(photo,dy:42,velocity:.slow)
        // Unmodified build32 treats this short control-origin drag as activation.
        // Preserve that native picker behavior rather than adding a control gesture.
        XCTAssertTrue(app.buttons["Cancel"].waitForExistence(timeout:4));app.buttons["Cancel"].tap()
        XCTAssertTrue(remove.exists);XCTAssertEqual(input.value as? String,draft)
        remove.tap();XCTAssertFalse(remove.exists)
        photo.tap()
        XCTAssertTrue(app.buttons["Cancel"].waitForExistence(timeout:4));app.buttons["Cancel"].tap()
        XCTAssertEqual(input.value as? String,draft);XCTAssertTrue(photo.exists);screenshot(app)
    }
    @MainActor func testSendAndStopControlsStayIndependent() {
        for useDrag in [false,true] {
            let (app,input)=open(["-slowAnswer"]);let draft=input.value as? String
            if useDrag {
                // This already activates Send in the unmodified native composer.
                drag(app.buttons["Send message"],dy:42,velocity:.slow)
            } else { app.buttons["Send message"].tap() }
            XCTAssertTrue(app.buttons["Stop"].waitForExistence(timeout:3));app.buttons["Stop"].tap()
            XCTAssertTrue(app.staticTexts["Stopped."].waitForExistence(timeout:4))
            XCTAssertTrue(app.staticTexts[draft!].exists,"The original draft was sent once")
            XCTAssertFalse(app.buttons["Stop"].exists);screenshot(app);app.terminate()
        }
    }

    @MainActor func testSmallComposerMovementPreservesEditing() {
        let (app,input)=open();let draft=input.value as? String
        drag(input,dy:12,velocity:.slow)
        XCTAssertTrue(app.keyboards.firstMatch.exists);XCTAssertEqual(input.value as? String,draft)
        input.typeText("!");XCTAssertTrue((input.value as? String ?? "").contains("!"));screenshot(app)
    }

    @MainActor func testShortInputHistoryDismissal() {
        let (app,input)=open();dismissViaHistory(app);hidden(app)
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
        let metrics=app.staticTexts["qa.editorMetrics"]
        expectation(for:NSPredicate(format:"label CONTAINS %@ AND NOT (label CONTAINS %@)","selection=","selection=0 "),evaluatedWith:metrics)
        waitForExpectations(timeout:3)
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
    @MainActor func testAccessibilityHistoryDismissal() {
        let (app,input)=open(["-accessibility"]);dismissViaHistory(app);hidden(app)
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
    @MainActor func testLongDraftHistoryDismissalPreservesText() {
        let (app,input)=open(["-longDraft"]);let draft=input.value as? String
        input.swipeUp(velocity:.slow)
        dismissViaHistory(app);hidden(app)
        XCTAssertEqual(input.value as? String,draft);screenshot(app)
    }
    @MainActor func testAccessibilityLongDraftHistoryDismissalPreservesText() {
        let (app,input)=open(["-accessibility","-longDraft"]);let draft=input.value as? String
        input.swipeUp(velocity:.slow)
        dismissViaHistory(app);hidden(app)
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
        dragTranscriptDown(app,input:input);hidden(app)
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

    @MainActor private func latestTailVisible(_ app:XCUIApplication,number:Int=23) {
        let tail=app.staticTexts.matching(NSPredicate(format:"label CONTAINS %@","ANSWER TAIL \(number)")).firstMatch
        XCTAssertTrue(tail.waitForExistence(timeout:5),"Latest answer tail exists")
        XCTAssertTrue(tail.isHittable,"Latest answer tail must actually be visible")
        let transcript=app.scrollViews["qa.transcript"]
        XCTAssertLessThanOrEqual(tail.frame.maxY,transcript.frame.maxY+1,"Latest answer must not extend below viewport")
        screenshot(app)
    }
    @MainActor func testLatestAnswerColdHistoryAndTabNavigation() {
        let app=XCUIApplication();app.launch()
        XCTAssertTrue(app.descendants(matching:.any)["qa.composer"].waitForExistence(timeout:12))
        latestTailVisible(app)
        app.buttons["ask.history"].tap();app.staticTexts["Other synthetic chat"].tap()
        latestTailVisible(app,number:1)
        app.buttons["ask.history"].tap();app.staticTexts["Keyboard long chat"].tap()
        latestTailVisible(app)
        app.scrollViews["qa.transcript"].swipeDown(velocity:.slow)
        app.buttons["ask.history"].tap();app.staticTexts["Keyboard long chat"].tap()
        latestTailVisible(app)
        app.scrollViews["qa.transcript"].swipeDown(velocity:.slow)
        app.tabBars.buttons["Cities"].tap();app.tabBars.buttons["Ask Feast"].tap()
        latestTailVisible(app)
    }
    @MainActor func testKeyboardAndDraftHeightPreserveIntentionalReadingPosition() {
        let app=XCUIApplication();app.launch()
        let input=app.descendants(matching:.any)["qa.composer"]
        XCTAssertTrue(input.waitForExistence(timeout:12));latestTailVisible(app)
        let transcript=app.scrollViews["qa.transcript"]
        transcript.swipeDown(velocity:.slow);transcript.swipeDown(velocity:.slow)
        let questions=app.staticTexts.matching(NSPredicate(format:"label BEGINSWITH %@","Synthetic question "))
        guard let question=questions.allElementsBoundByIndex.first(where:{$0.isHittable && $0.frame.minY>app.navigationBars.firstMatch.frame.maxY+10}) else {XCTFail("A prior question should be visible");return}
        let name=question.label;let y=question.frame.minY
        input.tap();XCTAssertTrue(app.keyboards.firstMatch.waitForExistence(timeout:4))
        XCTAssertEqual(app.staticTexts[name].frame.minY,y,accuracy:3,"Keyboard should not move the intentional reading position")
        input.typeText("\nMore draft\nThird draft line")
        XCTAssertEqual(app.staticTexts[name].frame.minY,y,accuracy:3,"Composer growth should not jump the reader")
        drag(input,dy:42,velocity:.slow);hidden(app)
        XCTAssertEqual(app.staticTexts[name].frame.minY,y,accuracy:3,"Composer-swipe dismissal should not jump the reader")
        screenshot(app)
    }

    @MainActor func testLatestAnswerEqualCountHistorySwitch() {
        let app=XCUIApplication();app.launchArguments=["-equalCount"];app.launch()
        XCTAssertTrue(app.descendants(matching:.any)["qa.composer"].waitForExistence(timeout:12))
        latestTailVisible(app)
        app.buttons["ask.history"].tap();app.staticTexts["Other synthetic chat"].tap()
        latestTailVisible(app,number:0)
        app.buttons["ask.history"].tap();app.staticTexts["Keyboard long chat"].tap()
        latestTailVisible(app)
    }
    @MainActor func testBottomPositionSurvivesKeyboardAndComposerGrowth() {
        let app=XCUIApplication();app.launch()
        let input=app.descendants(matching:.any)["qa.composer"]
        XCTAssertTrue(input.waitForExistence(timeout:12));latestTailVisible(app)
        input.tap();XCTAssertTrue(app.keyboards.firstMatch.waitForExistence(timeout:4));latestTailVisible(app)
        input.typeText("\nSecond line\nThird line\nFourth line")
        latestTailVisible(app)
        app.buttons["ask.history"].tap();hidden(app);app.buttons["Done"].tap();latestTailVisible(app)
    }
    @MainActor func testManualReturnToLatestKeepsBottomDuringKeyboardGrowth() {
        let app=XCUIApplication();app.launch()
        let input=app.descendants(matching:.any)["qa.composer"]
        XCTAssertTrue(input.waitForExistence(timeout:12));latestTailVisible(app)
        let transcript=app.scrollViews["qa.transcript"]
        transcript.swipeDown(velocity:.slow);transcript.swipeDown(velocity:.slow)
        for _ in 0..<4 {transcript.swipeUp(velocity:.fast)}
        latestTailVisible(app)
        input.tap();XCTAssertTrue(app.keyboards.firstMatch.waitForExistence(timeout:4));latestTailVisible(app)
        input.typeText("\nSecond line\nThird line")
        latestTailVisible(app);dismissViaHistory(app);latestTailVisible(app)
    }
    @MainActor func testShortHistoryKeyboardResizeKeepsLatest() {
        let app=XCUIApplication();app.launchArguments=["-turnCount=2"];app.launch()
        let input=app.descendants(matching:.any)["qa.composer"]
        XCTAssertTrue(input.waitForExistence(timeout:12));latestTailVisible(app,number:1)
        input.tap();XCTAssertTrue(app.keyboards.firstMatch.waitForExistence(timeout:4));latestTailVisible(app,number:1)
        input.typeText("\nSecond line\nThird line");latestTailVisible(app,number:1)
        dismissViaHistory(app);latestTailVisible(app,number:1)
    }
    @MainActor func testLongHistoryColdOpenAtLatest() {
        // Existing archive maximum; do not change application limits.
        let app=XCUIApplication();app.launchArguments=["-turnCount=100"];app.launch()
        XCTAssertTrue(app.descendants(matching:.any)["qa.composer"].waitForExistence(timeout:12))
        latestTailVisible(app,number:99)
        app.buttons["ask.history"].tap();app.staticTexts["Other synthetic chat"].tap()
        latestTailVisible(app,number:1)
        app.buttons["ask.history"].tap();app.staticTexts["Keyboard long chat"].tap()
        latestTailVisible(app,number:99)
    }
    @MainActor func testCollectionReceiptUndoStillUpdatesSavedRecord() {
        let app=XCUIApplication();app.launchArguments=["-collectionAction"];app.launch()
        let input=app.descendants(matching:.any)["qa.composer"]
        XCTAssertTrue(input.waitForExistence(timeout:12))
        XCTAssertEqual(app.staticTexts["qa.collectionName"].label,"Updated synthetic cafe")
        let view=app.buttons["View Updated synthetic cafe"]
        XCTAssertTrue(view.waitForExistence(timeout:5));XCTAssertTrue(view.isHittable)
        let undo=app.buttons["Undo this operation for 1 saved records"]
        XCTAssertTrue(undo.waitForExistence(timeout:5));XCTAssertTrue(undo.isHittable)
        undo.tap()
        expectation(for:NSPredicate(format:"label == %@","Synthetic Cafe"),evaluatedWith:app.staticTexts["qa.collectionName"])
        waitForExpectations(timeout:5)
        XCTAssertEqual(input.value as? String,"Unsent synthetic draft")
        XCTAssertFalse(undo.exists,"Completed Undo must not remain actionable")
        XCTAssertTrue(app.staticTexts["Undone · 1 place"].exists,"The existing receipt reflects the completed Undo")
        screenshot(app)
    }
    @MainActor func testPermissionProjectionShrinkLeavesVisibleTranscript() {
        let app=XCUIApplication();app.launchArguments=["-projection"];app.launch()
        XCTAssertTrue(app.descendants(matching:.any)["qa.composer"].waitForExistence(timeout:12));latestTailVisible(app)
        let transcript=app.scrollViews["qa.transcript"]
        transcript.swipeDown(velocity:.slow);transcript.swipeDown(velocity:.slow)
        app.buttons["qa.access"].tap()
        let placeholders=app.staticTexts.matching(NSPredicate(format:"label CONTAINS %@","Some earlier saved details are no longer available."))
        XCTAssertTrue(placeholders.firstMatch.waitForExistence(timeout:5))
        XCTAssertTrue(placeholders.allElementsBoundByIndex.contains { $0.isHittable },"Content shrink must not leave a blank viewport")
        screenshot(app)
        app.buttons["qa.access"].tap()
        let prose=app.staticTexts.matching(NSPredicate(format:"label CONTAINS %@","Synthetic answer paragraph"))
        XCTAssertTrue(prose.firstMatch.waitForExistence(timeout:5))
        XCTAssertTrue(prose.allElementsBoundByIndex.contains { $0.isHittable },"Restored content should remain visible")
        screenshot(app)
    }

}
