# Linear Issue Template — For Agent Consumption

> Write issues so an agent with zero context can produce a correct brainstorm.
> The agent will read VISION.md, ARCHITECTURE.md, and CLAUDE.md — but it won't know
> what you're thinking unless you write it here.

---

## Title
<!-- Verb-first, specific. "Add WhatsApp message retry on failure" not "WhatsApp improvements" -->

## Type
<!-- One of: feature | bug | tech-debt | refactor -->

## Problem Statement
<!-- What is broken, missing, or suboptimal? Write from the user's perspective.
     Bad:  "We need a retry mechanism"
     Good: "When WhatsApp message sending fails (network timeout, server error), the user
            sees no feedback and the message is silently lost. They have to manually check
            and resend." -->

## Desired Outcome
<!-- What should be true when this is done? Be concrete and testable.
     Bad:  "Messages should be more reliable"
     Good: "Failed WhatsApp messages are automatically retried up to 3 times with exponential
            backoff. User sees a 'retrying...' indicator. After 3 failures, message moves to
            'failed' state with a manual retry button." -->

## Scope Boundaries
<!-- What is explicitly IN and OUT of scope. Agents will gold-plate without this.
     IN:  retry logic, UI indicator, failed state
     OUT: message queue persistence across app restart, offline queuing -->

## Acceptance Criteria
<!-- Numbered, testable conditions. The QA agent will use these to write smoke tests.
     1. Sending a message with simulated network failure retries 3 times
     2. User sees retry indicator during retries
     3. After 3 failures, message shows "failed" with retry button
     4. Manual retry button triggers a fresh send attempt
     5. Successful retry clears the failed state -->

## Technical Hints (Optional)
<!-- If you know where the fix should go or what patterns to follow, say so.
     "Retry logic should live in twinning-agent's executor, not in the sidecar.
      Reference the existing save_progress tool for the event emission pattern." -->

## Related Issues / Context (Optional)
<!-- Link to related Linear issues, PRs, or docs that provide context.
     "Related to ENG-42 (WhatsApp connection stability). See also docs/brainstorms/2026-03-28-whatsapp-sidecar-baileys-v6-design.md" -->

## Priority Rationale (Optional)
<!-- Why is this priority what it is? Helps the orchestrator make sequencing decisions.
     "Blocking 3 users who reported lost messages this week. Must ship before broader rollout." -->
