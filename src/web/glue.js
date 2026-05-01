async function loadWasm(wasmUrl) {
    const importObject = {
        env: {
            // Standard web imports for freestanding Wasm
            print: (ptr, len) => {
                const memory = new Uint8Array(instance.exports.memory.buffer);
                const text = new TextDecoder().decode(memory.subarray(ptr, ptr + len));
                console.log(text);
            },
        },
    };

    let instance;
    if (WebAssembly.instantiateStreaming) {
        const { instance: inst } = await WebAssembly.instantiateStreaming(fetch(wasmUrl), importObject);
        instance = inst;
    } else {
        const response = await fetch(wasmUrl);
        const buffer = await response.arrayBuffer();
        const { instance: inst } = await WebAssembly.instantiate(buffer, importObject);
        instance = inst;
    }

    // Call an exported function to start execution
    // In our sample Zig code, we export 'wasm_main'
    if (instance.exports.wasm_main) {
        instance.exports.wasm_main();
    } else if (instance.exports.main) {
        instance.exports.main();
    } else if (instance.exports._start) {
        instance.exports._start();
    } else {
        console.log("Wasm loaded, but no wasm_main, main, or _start function found.");
    }

    return instance;
}

// Example usage:
// loadWasm('web-tes.wasm').then(instance => {
//     console.log("Wasm module loaded successfully.");
// });
