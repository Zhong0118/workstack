const spaces = {
  dev: { name: "开发", main: "编辑器", document: "工作区配置", tabs: ["浏览器", "终端"], pages: ["开发文档", "构建输出"], files: ["源文件", "项目资料"] },
  write: { name: "写作", main: "文稿", document: "文章草稿", tabs: ["预览", "备忘录"], pages: ["参考文献", "摘录"], files: ["手稿", "参考资料"] }
};

const workspaceButtons = [...document.querySelectorAll("[data-space]")];
const tabButtons = [...document.querySelectorAll(".tab")];
const desktop = document.querySelector(".desktop");
const selectedTabs = { dev: 0, write: 0 };
let workspace = "dev";

function render() {
  const space = spaces[workspace];
  const tab = selectedTabs[workspace];
  desktop.dataset.layout = workspace;
  desktop.dataset.tab = String(tab);
  workspaceButtons.forEach(button => button.setAttribute("aria-pressed", String(button.dataset.space === workspace)));
  tabButtons.forEach((button, index) => {
    button.textContent = space.tabs[index];
    button.setAttribute("aria-pressed", String(index === tab));
  });
  document.querySelector("#main-name").textContent = space.main;
  document.querySelector("#doc-label").textContent = space.document;
  document.querySelector("#side-label").textContent = space.pages[tab];
  document.querySelectorAll("#file-list span").forEach((item, index) => { item.textContent = space.files[index]; });
  document.querySelector("#demo-status").textContent = space.name + "工作区 · " + space.tabs[tab] + "在前";
}

workspaceButtons.forEach(button => button.addEventListener("click", () => { workspace = button.dataset.space; render(); }));
tabButtons.forEach((button, index) => button.addEventListener("click", () => { selectedTabs[workspace] = index; render(); }));

document.querySelector("#copy").addEventListener("click", async () => {
  const status = document.querySelector("#copy-status");
  try {
    await navigator.clipboard.writeText(document.querySelector("#commands").textContent);
    status.textContent = "命令已复制";
  } catch {
    status.textContent = "请选中上方命令并复制";
  }
});
