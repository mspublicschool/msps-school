/* ছবি বাছাই ও ক্রপ: ক্যামেরা বা ফাইল থেকে নেওয়া ছবি বর্গাকার করা হয়।
   index.html ও admin.html দুটোতেই ব্যবহৃত।
   window.pickAndCropPhoto(camera) -> Promise<Blob | null>  (বাতিল হলে null) */
(function () {
  const VIEW = 300;   // ক্রপ পর্দার মাপ (px)
  const OUT = 400;    // সংরক্ষিত ছবির মাপ (px)
  const btn = "padding:8px 12px;border:1px solid #e2e6ef;border-radius:8px;background:#fff;color:#14182b;cursor:pointer;font:inherit";

  function choosePhotoFile(camera) {
    return new Promise(resolve => {
      const inp = document.createElement("input");
      inp.type = "file";
      inp.accept = "image/*";
      if (camera) inp.setAttribute("capture", "environment");
      inp.onchange = () => resolve(inp.files && inp.files[0] ? inp.files[0] : null);
      inp.click();
    });
  }

  function openPhotoCrop(file) {
    return new Promise(resolve => {
      if (!file) return resolve(null);
      const url = URL.createObjectURL(file);
      const img = new Image();
      const wrap = document.createElement("div");
      wrap.style.cssText = "position:fixed;inset:0;background:rgba(0,0,0,.6);z-index:9999;display:flex;align-items:center;justify-content:center;padding:16px";
      wrap.innerHTML =
        `<div style="background:#fff;color:#14182b;border-radius:14px;padding:16px;width:100%;max-width:340px;text-align:center;font-family:'Noto Sans Bengali',system-ui,sans-serif">
          <div style="font-weight:700;margin-bottom:10px">ছবি ক্রপ করুন</div>
          <canvas width="${VIEW}" height="${VIEW}" style="width:${VIEW}px;max-width:100%;height:auto;aspect-ratio:1/1;border-radius:10px;background:#eef2f9;touch-action:none;cursor:move;border:1px solid #e2e6ef"></canvas>
          <div style="margin:10px 0;font-size:14px">জুম <input type="range" min="1" max="3" step="0.01" value="1" style="vertical-align:middle;width:60%"></div>
          <div style="display:flex;gap:8px;justify-content:center;flex-wrap:wrap">
            <button type="button" data-rot style="${btn}">৯০° ঘোরান</button>
            <button type="button" data-cancel style="${btn}">বাতিল</button>
            <button type="button" data-ok style="${btn};background:#1e2a78;color:#fff;border-color:#1e2a78">সংরক্ষণ</button>
          </div>
          <div style="font-size:12px;color:#5b6275;margin-top:8px">ছবিটি টেনে সরান, জুম দিয়ে বড় বা ছোট করুন।</div>
        </div>`;
      document.body.appendChild(wrap);
      const cv = wrap.querySelector("canvas");
      const ctx = cv.getContext("2d");
      const zoomEl = wrap.querySelector("input[type=range]");

      let rot = 0, src = null, zoom = 1, ox = 0, oy = 0, s0 = 1, drag = null;

      function buildSrc() {
        const w = img.naturalWidth, h = img.naturalHeight;
        const swap = rot % 180 !== 0;
        const c = document.createElement("canvas");
        c.width = swap ? h : w; c.height = swap ? w : h;
        const x = c.getContext("2d");
        x.translate(c.width / 2, c.height / 2);
        x.rotate(rot * Math.PI / 180);
        x.drawImage(img, -w / 2, -h / 2);
        return c;
      }
      function geom() {
        const dw = src.width * s0 * zoom, dh = src.height * s0 * zoom;
        return { dw, dh, x: (VIEW - dw) / 2 + ox, y: (VIEW - dh) / 2 + oy };
      }
      function clampPan() {
        const { dw, dh } = geom();
        const mx = Math.max(0, (dw - VIEW) / 2), my = Math.max(0, (dh - VIEW) / 2);
        ox = Math.min(mx, Math.max(-mx, ox));
        oy = Math.min(my, Math.max(-my, oy));
      }
      function draw() {
        clampPan();
        const { dw, dh, x, y } = geom();
        ctx.fillStyle = "#eef2f9";
        ctx.fillRect(0, 0, VIEW, VIEW);
        ctx.drawImage(src, x, y, dw, dh);
      }
      function init() {
        src = buildSrc();
        s0 = VIEW / Math.min(src.width, src.height);
        ox = 0; oy = 0;
        draw();
      }

      img.onload = () => { init(); };
      img.onerror = () => { cleanup(); resolve(null); };
      img.src = url;

      function cleanup() {
        wrap.remove();
        URL.revokeObjectURL(url);
      }

      cv.addEventListener("pointerdown", e => {
        drag = { x: e.clientX, y: e.clientY };
        cv.setPointerCapture(e.pointerId);
      });
      cv.addEventListener("pointermove", e => {
        if (!drag) return;
        const k = VIEW / cv.getBoundingClientRect().width;
        ox += (e.clientX - drag.x) * k;
        oy += (e.clientY - drag.y) * k;
        drag = { x: e.clientX, y: e.clientY };
        draw();
      });
      const endDrag = () => { drag = null; };
      cv.addEventListener("pointerup", endDrag);
      cv.addEventListener("pointercancel", endDrag);

      zoomEl.addEventListener("input", () => { zoom = +zoomEl.value; draw(); });
      wrap.querySelector("[data-rot]").onclick = () => { rot = (rot + 90) % 360; init(); };
      wrap.querySelector("[data-cancel]").onclick = () => { cleanup(); resolve(null); };
      wrap.querySelector("[data-ok]").onclick = () => {
        const out = document.createElement("canvas");
        out.width = OUT; out.height = OUT;
        const o = out.getContext("2d");
        o.fillStyle = "#ffffff";
        o.fillRect(0, 0, OUT, OUT);
        const { dw, dh, x, y } = geom();
        const k = OUT / VIEW;
        o.drawImage(src, x * k, y * k, dw * k, dh * k);
        out.toBlob(blob => { cleanup(); resolve(blob); }, "image/jpeg", 0.85);
      };
    });
  }

  window.choosePhotoFile = choosePhotoFile;
  window.openPhotoCrop = openPhotoCrop;
  window.pickAndCropPhoto = async function (camera) {
    return openPhotoCrop(await choosePhotoFile(camera));
  };
})();
