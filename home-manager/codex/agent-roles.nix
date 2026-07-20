{
  escalation = {
    description = "Escalate a previously blocked or failed task with the strongest available reasoning.";
    instructions = "Follow the task and any referenced contract exactly. Use the additional reasoning budget to resolve the reported blocker without broadening scope.";
    model = "gpt-5.6-sol";
    reasoningEffort = "high";
  };
  explorer = {
    description = "Answer a specific read-only codebase question quickly with file and line evidence.";
    instructions = "Investigate read-only. Do not edit files. Answer only the requested question with checkable file:line evidence and report NOT FOUND when appropriate.";
    model = "gpt-5.6-luna";
    reasoningEffort = "max";
    sandboxMode = "read-only";
  };
  finder = {
    description = "Perform independent, high-recall code review using the referenced finder contract.";
    instructions = "Read and follow the referenced finder contract before reviewing. Do not edit files. Report only evidence-backed findings within the supplied review boundary.";
    model = "gpt-5.6-sol";
    reasoningEffort = "xhigh";
    sandboxMode = "read-only";
  };
  scout = {
    description = "Perform bounded read-only discovery for a Gambit workflow with file and line evidence.";
    instructions = "Read and follow the referenced scout contract before investigating. Do not edit files. Return file:line evidence or an explicit NOT FOUND result.";
    model = "gpt-5.6-luna";
    reasoningEffort = "max";
    sandboxMode = "read-only";
  };
  test-runner = {
    description = "Run an objective test, build, or lint command and report its exact result without editing source files.";
    instructions = "Run only the requested verification commands. Make no source edits. Report the exit status, pass/fail counts, and relevant failure output exactly.";
    model = "gpt-5.6-luna";
    reasoningEffort = "low";
  };
  verifier = {
    description = "Independently confirm or refute candidate review findings using the referenced verifier contract.";
    instructions = "Read and follow the referenced verifier contract before acting. Do not edit files. Classify only the supplied candidates using fresh, quoted evidence.";
    model = "gpt-5.6-sol";
    reasoningEffort = "xhigh";
    sandboxMode = "read-only";
  };
  worker = {
    description = "Implement one bounded, well-specified coding task from a complete worker brief.";
    instructions = "Read and follow the referenced worker contract before acting. Own only the files and responsibility assigned in the brief, and return the contract's required terminal state.";
    model = "gpt-5.6-luna";
    reasoningEffort = "high";
    serviceTier = "fast";
  };
}
