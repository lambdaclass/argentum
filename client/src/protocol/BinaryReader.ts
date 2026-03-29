export class BinaryReader {
  private readonly view: DataView;
  private offset = 0;

  constructor(buffer: ArrayBuffer) {
    this.view = new DataView(buffer);
  }

  remaining() {
    return this.view.byteLength - this.offset;
  }

  readUint8() {
    const value = this.view.getUint8(this.offset);
    this.offset += 1;
    return value;
  }

  readInt16() {
    const value = this.view.getInt16(this.offset, true);
    this.offset += 2;
    return value;
  }

  readUint16() {
    const value = this.view.getUint16(this.offset, true);
    this.offset += 2;
    return value;
  }

  readInt32() {
    const value = this.view.getInt32(this.offset, true);
    this.offset += 4;
    return value;
  }

  readFloat32() {
    const value = this.view.getFloat32(this.offset, true);
    this.offset += 4;
    return value;
  }

  readBool() {
    return this.readUint8() !== 0;
  }

  readString8() {
    const length = this.readUint16();
    let output = "";

    for (let index = 0; index < length; index += 1) {
      output += String.fromCharCode(this.readUint8());
    }

    return output;
  }
}
