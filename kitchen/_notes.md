** Replace submodule to submodule of the fork

  git submodule set-url vendor/odin-http https://github.com/g41797/odin-http

  git submodule update --remote vendor/odin-http

**How to commit&push submodule**


---

  Phase 1: Commit and Push Changes in the Submodule (Directly on main)


   1. Navigate into the submodule directory:
   1     # Run from: root of main project
   2     cd vendor/odin-http


   2. Switch to the main branch:
       * This will move your HEAD off the detached state and onto the main branch.
   1     # Run from: vendor/odin-http
   2     git switch main


   3. Pull latest changes from your remote fork's main branch:
       * This is crucial to ensure your local main is up-to-date before you make new commits, preventing potential conflicts when you push.
   1     # Run from: vendor/odin-http
   2     git pull origin main

   4. Make your desired changes to the files.

   5. Stage your changes:


   1     # Run from: vendor/odin-http
   2     git add .

   6. Commit your changes:
   1     # Run from: vendor/odin-http
   2     git commit -m "feat: Implement my new feature or fix in odin-http"


   7. Push your changes to your remote fork's main branch:
   1     # Run from: vendor/odin-http
   2     git push origin main

   8. Navigate back to the root of your main project:


   1     # Run from: vendor/odin-http
   2     cd ../..

  ---

  Phase 2: Commit and Push the Submodule Reference in the Parent Repository


   1. Check status in the parent repository:
       * You will now see that vendor/odin-http is listed as modified. This means the parent repository detects that the submodule is pointing to
         the new commit ID you just pushed.
   1     # Run from: root of main project
   2     git status
   3     # Expected output will include 'modified: vendor/odin-http (new commits)'


   2. Stage the submodule reference change:
   1     # Run from: root of main project
   2     git add vendor/odin-http

   3. Commit the submodule reference change:


   1     # Run from: root of main project
   2     git commit -m "Update odin-http submodule to include [brief description of changes]"


   4. Push the parent commit to its remote:
   1     # Run from: root of main project
   2     git push origin main



---


    Prerequisite: You have VS Code open to the root of your main project (matryoshka-http-template).

  Step 1: Commit and Push Changes within the Submodule

  This is for the actual code modifications you made inside vendor/odin-http.


   1. Make Changes: Edit the files you need to within the vendor/odin-http/ directory.
   2. Open Source Control: Go to the Source Control view (the Git icon in the left Activity Bar, or press Ctrl+Shift+G).
   3. Switch Git Context to Submodule:
       * At the very top of the Source Control view, you'll see a dropdown menu that currently shows your main repository (e.g.,
         matryoshka-http-template).
       * Click this dropdown. You should see an entry for your submodule, likely named something like odin-http (vendor/odin-http). Select this
         entry.
       * VS Code's Git view will now show the changes specific to the odin-http submodule.
   4. Stage Changes (in Submodule):
       * In the "Changes" section, hover over Changes and click the + icon (or Ctrl+Enter) to "Stage All Changes" within the submodule.
   5. Commit Changes (in Submodule):
       * Type a clear, descriptive commit message in the message box at the top (e.g., "Fix: Implement non-blocking wait in nbio_windows.odin").
       * Click the "Commit" button (the checkmark icon) or press Ctrl+Enter again.
   6. Push Changes (from Submodule):
       * Click the "..." (More Actions) menu in the Source Control view.
       * Select Push (or Sync Changes if you want to both fetch and push). This will push your submodule's new commit(s) to its remote repository
         (your forked g41797/odin-http).

  Step 2: Commit the Submodule Reference Change in the Parent Repository

  Now, your main project needs to record that it's using this new, updated version of your odin-http submodule.


   1. Switch Git Context Back to Main Repository:
       * Go back to the Source Control view.
       * Click the dropdown menu at the top (which now shows odin-http (vendor/odin-http)).
       * Select your main repository (e.g., matryoshka-http-template).
   2. Observe the Submodule Change:
       * In the "Changes" section for your main repository, you will now see an entry that looks like:
   1         vendor/odin-http
          This entry will indicate that the submodule has "new commits" or is "modified". This means the recorded reference (the specific commit
  hash) of the submodule has changed.
   3. Stage the Submodule Reference:
       * Hover over the vendor/odin-http entry in the "Changes" list and click the + icon to stage it.
   4. Commit the Submodule Reference:
       * Type a commit message, such as "Update odin-http submodule to include nbio fix for Windows."
       * Click the "Commit" button.
   5. Push Changes (from Main Repository):
       * Click the "..." (More Actions) menu.
       * Select Push (or Sync Changes). This will push this commit to your main project's remote repository.


  After these steps, your main project's remote repository will correctly point to the updated version of your forked odin-http submodule, ensuring
  anyone who clones your main project gets your latest changes in the submodule too.
